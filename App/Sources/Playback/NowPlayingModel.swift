import Combine
import Foundation
import LyricsCore

/// The single source of truth shared by the iPhone and CarPlay screens:
/// what Spotify is playing, where in the song it is, and which lyric line is current.
@MainActor
final class NowPlayingModel: ObservableObject {
    static let shared = NowPlayingModel()

    enum LyricsState: Equatable {
        case none
        case loading
        case loaded(Lyrics)
        case failed(String)
    }

    struct Snapshot: Equatable {
        var isSignedIn = false
        var track: NowPlayingTrack?
        var isPlaying = false
        var lyrics: LyricsState = .none
        /// Index into the synced lyrics of the line being sung, nil before the first line.
        var currentLine: Int?
        /// Shown when Spotify can't be reached; cleared on the next good poll.
        var problem: String?
    }

    @Published private(set) var snapshot = Snapshot()

    /// Seconds added to the playback position before picking a line.
    /// Positive values show lyrics earlier.
    @Published var timingOffset: Double {
        didSet {
            UserDefaults.standard.set(timingOffset, forKey: Self.offsetKey)
            tick()
        }
    }

    private let auth = SpotifyAuth.shared
    private let api = SpotifyAPI()
    private let repository = LyricsRepository.shared

    private var clock: PlaybackClock?
    private var activeClients: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var lyricsFailedAt: TimeInterval?
    private var pollSoon = false
    private var lastPollAt: TimeInterval = 0

    private static let offsetKey = "timingOffset"
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private init() {
        timingOffset = UserDefaults.standard.double(forKey: Self.offsetKey)
        snapshot.isSignedIn = auth.isSignedIn
        Task { [weak self] in
            for await signedIn in SpotifyAuth.shared.$isSignedIn.values {
                self?.authChanged(signedIn)
            }
        }
    }

    // MARK: Lifecycle

    /// Screens call this when they appear or disappear. Spotify is only polled
    /// while at least one screen (the iPhone app or CarPlay) is showing.
    func setActive(_ active: Bool, client: String) {
        if active {
            activeClients.insert(client)
        } else {
            activeClients.remove(client)
        }
        updateLoops()
    }

    func refreshNow() {
        pollSoon = true
    }

    func adjustOffset(by delta: Double) {
        timingOffset = ((timingOffset + delta) * 20).rounded() / 20
    }

    /// The estimated playback position including the timing offset.
    func estimatedPosition() -> TimeInterval? {
        guard let clock else { return nil }
        return clock.position(at: Self.now) + timingOffset
    }

    private func authChanged(_ signedIn: Bool) {
        guard snapshot.isSignedIn != signedIn else { return }
        snapshot.isSignedIn = signedIn
        if !signedIn {
            clock = nil
            lyricsTask?.cancel()
            snapshot = Snapshot(isSignedIn: false)
        }
        updateLoops()
    }

    private func updateLoops() {
        let shouldRun = !activeClients.isEmpty && auth.isSignedIn
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

    // MARK: Polling Spotify

    private func pollLoop() async {
        while !Task.isCancelled {
            let delay = await poll()
            let deadline = Self.now + delay
            pollSoon = false
            while !Task.isCancelled, !pollSoon, Self.now < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Asks Spotify what is playing and returns how long to wait before asking again.
    private func poll() async -> TimeInterval {
        lastPollAt = Self.now
        do {
            var token = try await auth.accessToken()
            var sample: PlaybackSample
            var start = Self.now
            do {
                sample = try await api.currentlyPlaying(accessToken: token)
            } catch SpotifyAPI.Failure.unauthorized {
                token = try await auth.accessToken(forceRefresh: true)
                start = Self.now
                sample = try await api.currentlyPlaying(accessToken: token)
            }
            // Spotify measured the position somewhere during the request; the midpoint is the best guess.
            let measuredAt = (start + Self.now) / 2
            apply(sample, measuredAt: measuredAt)
            snapshot.problem = nil
            if sample.track == nil { return 6 }
            return sample.isPlaying ? 3 : 5
        } catch SpotifyAPI.Failure.rateLimited(let retryAfter) {
            return max(retryAfter, 3)
        } catch SpotifyAuthError.notSignedIn {
            return 10
        } catch is CancellationError {
            return 0
        } catch {
            snapshot.problem = "Can't reach Spotify. Retrying…"
            return 5
        }
    }

    private func apply(_ sample: PlaybackSample, measuredAt time: TimeInterval) {
        guard let track = sample.track else {
            clock = nil
            lyricsTask?.cancel()
            if snapshot.track != nil || snapshot.isPlaying {
                snapshot.track = nil
                snapshot.isPlaying = false
                snapshot.lyrics = .none
                snapshot.currentLine = nil
            }
            return
        }

        if track.id != snapshot.track?.id {
            clock = PlaybackClock(position: sample.position, at: time, isPlaying: sample.isPlaying, duration: track.duration)
            snapshot.track = track
            snapshot.currentLine = nil
            loadLyrics(for: track)
        } else {
            if clock == nil {
                clock = PlaybackClock(position: sample.position, at: time, isPlaying: sample.isPlaying, duration: track.duration)
            } else {
                clock?.update(position: sample.position, at: time, isPlaying: sample.isPlaying, duration: track.duration)
            }
            if case .failed = snapshot.lyrics, let failedAt = lyricsFailedAt, Self.now - failedAt > 20 {
                loadLyrics(for: track)
            }
        }
        if snapshot.isPlaying != sample.isPlaying {
            snapshot.isPlaying = sample.isPlaying
        }
        tick()
    }

    private func loadLyrics(for track: NowPlayingTrack) {
        lyricsTask?.cancel()
        lyricsFailedAt = nil
        snapshot.lyrics = .loading
        lyricsTask = Task { [weak self, repository] in
            do {
                let lyrics = try await repository.lyrics(for: track)
                guard let self, !Task.isCancelled, self.snapshot.track?.id == track.id else { return }
                self.snapshot.lyrics = .loaded(lyrics)
                self.tick()
            } catch {
                guard let self, !Task.isCancelled, self.snapshot.track?.id == track.id else { return }
                self.lyricsFailedAt = Self.now
                self.snapshot.lyrics = .failed("Couldn't load lyrics. Retrying soon.")
            }
        }
    }

    // MARK: Following the song

    private func tickLoop() async {
        while !Task.isCancelled {
            tick()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func tick() {
        guard let clock else { return }
        let now = Self.now

        // The song probably changed; don't wait for the next scheduled poll.
        if clock.hasReachedEnd(at: now), now - lastPollAt > 1.5 {
            pollSoon = true
        }

        guard case .loaded(.synced(let timeline)) = snapshot.lyrics else { return }
        let line = timeline.index(at: clock.position(at: now) + timingOffset)
        if line != snapshot.currentLine {
            snapshot.currentLine = line
        }
    }
}
