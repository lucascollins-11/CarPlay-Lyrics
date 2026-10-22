import Combine
import Foundation
import LyricsCore

/// The single source of truth shared by the iPhone screen, CarPlay and the
/// Live Activity: what is playing, where in the song it is, and which lyric
/// line is current. The decisions live in `NowPlayingEngine`; this class runs
/// the timers and network calls around it.
@MainActor
final class NowPlayingModel: ObservableObject {
    /// What the model talks to. Swapped for fakes in tests.
    struct Dependencies {
        var spotify: PlaybackSource
        var lyrics: LyricsProvider
        /// The disk cache behind `lyrics`, when there is one (clearing, "chosen by you").
        var store: LyricsStore?
        var demo: DemoPlayback
        var demoLyrics: LyricsProvider
        /// Monotonic seconds.
        var now: @Sendable () -> TimeInterval

        static func live(auth: SpotifyAuth) -> Dependencies {
            AppConfig.prepareLyricsDirectory()
            let store = LyricsStore(client: LRCLibClient(userAgent: AppConfig.lrclibUserAgent),
                                    directory: AppConfig.lyricsDirectory)
            let spotify = SpotifyWebAPI(http: URLSession.shared) { force in
                try await auth.accessToken(forceRefresh: force)
            }
            return Dependencies(spotify: spotify, lyrics: store, store: store, demo: DemoPlayback(),
                                demoLyrics: DemoLyricsProvider(), now: MonotonicClock.now)
        }
    }

    @Published private(set) var snapshot: NowPlayingSnapshot
    /// The phone's current audio output (see `AudioRouteMonitor`).
    @Published private(set) var audioRoute: AudioRouteKind = .speaker
    /// A short-lived message after a failed jump to a line.
    @Published var seekMessage: String?

    let settings: AppSettings
    let auth: SpotifyAuth
    private let deps: Dependencies
    private var engine: NowPlayingEngine

    private var activeClients: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    /// Set to poll right away instead of waiting out the current delay.
    private var pollSoon = false {
        didSet { if pollSoon { pollWait?.cancel() } }
    }
    private var pollWait: Task<Void, Never>?
    private var tickWait: Task<Void, Never>?
    /// Bumped when switching between Spotify and demo, so late answers from the old source are dropped.
    private var sourceGeneration = 0
    private var subscriptions: Set<AnyCancellable> = []

    init(settings: AppSettings, auth: SpotifyAuth, dependencies: Dependencies) {
        self.settings = settings
        self.auth = auth
        self.deps = dependencies
        let isDemo = settings.demoMode || LaunchOptions.forceDemo
        engine = NowPlayingEngine(globalOffset: settings.offset(for: .speaker), trackOffsets: settings.trackOffsets,
                                  isSignedIn: auth.isSignedIn, isDemo: isDemo)
        snapshot = engine.snapshot

        auth.$isSignedIn
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] signedIn in self?.authChanged(signedIn) }
            .store(in: &subscriptions)
        // The new values come with the event (the properties still hold the old ones while sinks run).
        settings.$globalOffset.combineLatest(settings.$routeOffsets, $audioRoute)
            .dropFirst()
            .sink { [weak self] global, routes, route in self?.globalOffsetChanged(routes[route.rawValue] ?? global) }
            .store(in: &subscriptions)
        settings.$demoMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] demo in self?.setDemo(demo || LaunchOptions.forceDemo) }
            .store(in: &subscriptions)
    }

    var isDemo: Bool { engine.snapshot.isDemo }
    private var source: PlaybackSource { isDemo ? deps.demo : deps.spotify }
    private var lyricsProvider: LyricsProvider { isDemo ? deps.demoLyrics : deps.lyrics }
    // The engine's flag, not auth.isSignedIn: @Published sinks run before the new value is stored.
    private var canRun: Bool { isDemo || engine.snapshot.isSignedIn }
    var isRunning: Bool { pollTask != nil }

    /// Seeking is possible in demo mode, or with the extra Spotify permission turned on.
    var canSeek: Bool { isDemo || (settings.allowSeeking && auth.canSeek) }

    // MARK: Lifecycle

    /// Screens and Drive mode call this as they appear and disappear. Spotify
    /// is only polled while at least one of them is active.
    func setActive(_ active: Bool, client: String) {
        if active {
            activeClients.insert(client)
        } else {
            activeClients.remove(client)
        }
        updateLoops()
    }

    func isActive(client: String) -> Bool { activeClients.contains(client) }

    /// The network came back after an outage: poll now instead of waiting out the backoff.
    func networkRestored() {
        engine.networkRestored(at: deps.now())
        pollSoon = true
    }

    /// Asks Spotify again right away (pull to refresh, app became active).
    func refreshNow() {
        engine.noteUserAction(at: deps.now())
        pollSoon = true
    }

    private func updateLoops() {
        let shouldRun = !activeClients.isEmpty && canRun
        if shouldRun, pollTask == nil {
            pollTask = Task { [weak self] in await self?.pollLoop() }
            tickTask = Task { [weak self] in await self?.tickLoop() }
        } else if !shouldRun, pollTask != nil {
            pollTask?.cancel()
            tickTask?.cancel()
            pollTask = nil
            tickTask = nil
        }
    }

    private func authChanged(_ signedIn: Bool) {
        guard !isDemo else { return }
        if signedIn {
            engine.setSignedIn(true)
        } else {
            cancelWork()
            engine.setSignedIn(false)
        }
        publish()
        updateLoops()
        refreshNow()
    }

    private func setDemo(_ demo: Bool) {
        guard demo != isDemo else { return }
        sourceGeneration += 1
        cancelWork()
        engine.reset(isSignedIn: auth.isSignedIn, isDemo: demo)
        publish()
        // Restart the loops against the new source.
        pollTask?.cancel()
        tickTask?.cancel()
        pollTask = nil
        tickTask = nil
        updateLoops()
    }

    /// Which audio output the phone uses now; picks the timing adjustment for it.
    func setAudioRoute(_ route: AudioRouteKind) {
        if route != audioRoute { audioRoute = route }
    }

    private func globalOffsetChanged(_ offset: Double) {
        guard offset != engine.globalOffset else { return }
        engine.globalOffset = offset
        engine.tick(at: deps.now())
        publish()
        wakeTick()
    }

    private func cancelWork() {
        lyricsTask?.cancel()
        prefetchTask?.cancel()
        lyricsTask = nil
        prefetchTask = nil
    }

    // MARK: Polling

    private func pollLoop() async {
        while !Task.isCancelled {
            // Cleared before the request, so a refresh asked for while it runs isn't lost.
            pollSoon = false
            let delay = await pollOnce()
            if pollSoon { continue }
            // Sleep the whole delay; refreshNow() and early polls cut it short by cancelling the wait.
            let wait = Self.sleeper(seconds: delay)
            pollWait = wait
            await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
            pollWait = nil
        }
    }

    private static func sleeper(seconds: TimeInterval) -> Task<Void, Never> {
        Task { try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
    }

    /// Re-plans the tick loop's sleep, for example after the clock jumped.
    private func wakeTick() {
        tickWait?.cancel()
    }

    /// Asks the source what is playing once. Returns how long to wait before asking again.
    @discardableResult
    func pollOnce() async -> TimeInterval {
        let generation = sourceGeneration
        let source = self.source
        let start = deps.now()
        do {
            let sample = try await source.currentlyPlaying()
            guard generation == sourceGeneration else { return 0 }
            // Spotify measured the position somewhere during the HTTP exchange; the midpoint is the
            // best guess. Use the source's own timing of the final exchange when it has one, so a
            // token refresh or retry before it doesn't make the lyrics late.
            let requestStart = sample.requestStart ?? start
            let requestEnd = sample.requestEnd ?? deps.now()
            perform(engine.apply(sample, at: (requestStart + requestEnd) / 2,
                                 uncertainty: max(0, requestEnd - requestStart) / 2))
            publish()
            wakeTick()
            return engine.nextPollDelay(at: deps.now())
        } catch {
            guard generation == sourceGeneration else { return 0 }
            let delay = engine.pollFailed(error, at: deps.now())
            if engine.needsSignIn, !isDemo {
                // Spotify keeps refusing even fresh tokens (for example the app's settings changed
                // in the Spotify dashboard). Bring back the sign-in screen instead of failing quietly.
                auth.signOut()
            }
            publish()
            return delay
        }
    }

    private func perform(_ effects: [NowPlayingEngine.Effect]) {
        for effect in effects {
            switch effect {
            case .loadLyrics(let track):
                loadLyrics(for: track)
            case .cancelLyrics:
                lyricsTask?.cancel()
                lyricsTask = nil
            case .prefetchUpcoming:
                prefetchUpcoming()
            }
        }
    }

    private func loadLyrics(for track: NowPlayingTrack) {
        lyricsTask?.cancel()
        let provider = lyricsProvider
        let store = isDemo ? nil : deps.store
        lyricsTask = Task { [weak self] in
            do {
                let lyrics = try await provider.lyrics(for: track)
                let chosen = await store?.isChosenByUser(track) ?? false
                guard let self, !Task.isCancelled else { return }
                self.engine.lyricsLoaded(lyrics, for: track.id, chosenByUser: chosen, at: self.deps.now())
                self.publish()
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.engine.lyricsFailed("Couldn't load lyrics", for: track.id, at: self.deps.now())
                self.publish()
            }
        }
    }

    /// Fetches lyrics for the next couple of songs so they show instantly, even with patchy signal.
    private func prefetchUpcoming() {
        // Prefetching is optional; don't spend Spotify's rate limit on it while it's tight.
        guard !isDemo, !engine.isRateLimited(at: deps.now()) else { return }
        prefetchTask?.cancel()
        let source = self.source
        let provider = lyricsProvider
        prefetchTask = Task {
            // Give the current song's lookup a head start.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let upcoming = try? await source.upcomingTracks() else { return }
            for track in upcoming.prefix(2) where !Task.isCancelled {
                _ = try? await provider.lyrics(for: track)
            }
        }
    }

    // MARK: Following the song

    private func tickLoop() async {
        while !Task.isCancelled {
            tick()
            // Sleep until the next line is due (at most a second) instead of waking 10 times a second.
            let wait = Self.sleeper(seconds: engine.nextTickDelay(at: deps.now()))
            tickWait = wait
            await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
            tickWait = nil
        }
    }

    func tick() {
        let now = deps.now()
        let changed = engine.tick(at: now)
        if engine.takeEarlyPoll(at: now) {
            // The song should have ended; find out what's next without waiting.
            pollSoon = true
        }
        if changed { publish() }
    }

    private func publish() {
        let new = engine.snapshot
        if new != snapshot {
            snapshot = new
            wakeTick()
        }
    }

    /// The estimated position in the song including timing offsets.
    func estimatedPosition() -> TimeInterval? {
        engine.position(at: deps.now())
    }

    var effectiveOffset: TimeInterval { engine.effectiveOffset }

    // MARK: User actions

    /// Shifts this song's lyrics. Positive shows them earlier.
    func adjustTrackOffset(by delta: Double) {
        engine.adjustTrackOffset(by: delta, at: deps.now())
        settings.trackOffsets = engine.trackOffsets
        publish()
    }

    func resetTrackOffset() {
        engine.resetTrackOffset(at: deps.now())
        settings.trackOffsets = engine.trackOffsets
        publish()
    }

    /// Jumps playback to the start of `line` (iPhone only; never offered in CarPlay).
    func seek(toLine line: Int) async {
        guard canSeek, let position = engine.seekPosition(forLine: line) else { return }
        engine.seekLocally(to: position, at: deps.now())
        publish()
        wakeTick()
        do {
            try await source.seek(to: position)
        } catch {
            seekMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't jump to that line."
        }
        refreshNow()
    }

    /// Demo mode only: play or pause the built-in song.
    func toggleDemoPlayback() {
        guard isDemo else { return }
        deps.demo.setPlaying(!deps.demo.isPlaying)
        refreshNow()
    }

    /// Other versions of this song's lyrics on LRCLIB.
    func lyricCandidates() async throws -> [LRCLibRecord] {
        guard let track = snapshot.track else { return [] }
        return try await lyricsProvider.candidates(for: track)
    }

    func chooseLyrics(_ record: LRCLibRecord) async throws {
        guard let track = snapshot.track else { return }
        lyricsTask?.cancel()
        let lyrics = try await lyricsProvider.choose(record, for: track)
        engine.lyricsLoaded(lyrics, for: track.id, chosenByUser: !isDemo, at: deps.now())
        publish()
    }

    func resetLyricsChoice() async throws {
        guard let track = snapshot.track else { return }
        lyricsTask?.cancel()
        let lyrics = try await lyricsProvider.resetChoice(for: track)
        engine.lyricsLoaded(lyrics, for: track.id, chosenByUser: false, at: deps.now())
        publish()
    }

    func cachedSongCount() async -> Int {
        await deps.store?.cachedCount() ?? 0
    }

    func clearLyricsCache() async {
        await deps.store?.clear()
        // Reload the current song so the screen isn't left with lyrics that are no longer stored.
        if let track = snapshot.track, !isDemo {
            loadLyrics(for: track)
        }
    }

    /// "Delete my data": signs out, clears the lyrics cache and every preference.
    func deleteAllData() async {
        cancelWork()
        await deps.store?.clear()
        settings.deleteAll()
        auth.signOut()
        engine = NowPlayingEngine(globalOffset: settings.offset(for: audioRoute), isSignedIn: false, isDemo: LaunchOptions.forceDemo)
        sourceGeneration += 1
        publish()
        pollTask?.cancel()
        tickTask?.cancel()
        pollTask = nil
        tickTask = nil
        updateLoops()
    }
}
