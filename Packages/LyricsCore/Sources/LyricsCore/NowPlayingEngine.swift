import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LyricsState: Equatable, Sendable {
    case none
    case loading
    case loaded(Lyrics)
    case failed(String)
}

/// Everything the screens need to draw, in one value.
public struct NowPlayingSnapshot: Equatable, Sendable {
    public var isSignedIn: Bool
    public var isDemo: Bool
    public var track: NowPlayingTrack?
    public var isPlaying: Bool
    public var lyrics: LyricsState
    /// Index into the synced lyrics of the line being sung, nil before the first line.
    public var currentLine: Int?
    /// True when the user picked this song's lyrics by hand.
    public var lyricsChosenByUser: Bool
    /// A problem worth telling the user about. Cleared by the next good poll.
    public var problem: String?
    /// Timing adjustment for this song only, in seconds (positive shows lyrics earlier).
    public var trackOffset: TimeInterval

    public init(isSignedIn: Bool = false, isDemo: Bool = false, track: NowPlayingTrack? = nil, isPlaying: Bool = false,
                lyrics: LyricsState = .none, currentLine: Int? = nil, lyricsChosenByUser: Bool = false,
                problem: String? = nil, trackOffset: TimeInterval = 0) {
        self.isSignedIn = isSignedIn
        self.isDemo = isDemo
        self.track = track
        self.isPlaying = isPlaying
        self.lyrics = lyrics
        self.currentLine = currentLine
        self.lyricsChosenByUser = lyricsChosenByUser
        self.problem = problem
        self.trackOffset = trackOffset
    }

    public var timeline: LyricsTimeline? {
        if case .loaded(.synced(let timeline)) = lyrics { return timeline }
        return nil
    }
}

/// The decisions behind following a song, kept free of networking and timers
/// so they can be unit tested. The app feeds it samples, errors and clock
/// ticks, and carries out the effects it returns.
public struct NowPlayingEngine: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Start loading lyrics for this track (cancel any other load).
        case loadLyrics(NowPlayingTrack)
        /// Stop any lyrics load in progress.
        case cancelLyrics
        /// A new song started; look up what's next and prefetch its lyrics.
        case prefetchUpcoming
    }

    public static let unreachableMessage = "Can't reach Spotify. Retrying…"

    public private(set) var snapshot: NowPlayingSnapshot
    public private(set) var clock: PlaybackClock?
    /// Seconds added to every song's position before picking a line (for
    /// example to make up for Bluetooth delay). Positive shows lyrics earlier.
    public var globalOffset: TimeInterval
    /// Per-song adjustments on top of `globalOffset`, keyed by track ID.
    public private(set) var trackOffsets: [String: TimeInterval]
    /// Wait this long before retrying lyrics that failed to load.
    public var lyricsRetryInterval: TimeInterval = 20

    private var lyricsFailedAt: TimeInterval?
    private var lastSampleAt: TimeInterval?
    private var fastPollUntil: TimeInterval = 0
    private var earlyPollsThisTrack = 0
    private var consecutiveFailures = 0

    /// After a change (new song, pause, seek), poll quickly for this long to catch follow-up changes.
    public static let fastPollWindow: TimeInterval = 5
    public static let fastPollInterval: TimeInterval = 1.25
    /// How many times to re-poll early while a song sits at its end.
    public static let maxEarlyPolls = 4

    public init(globalOffset: TimeInterval = 0, trackOffsets: [String: TimeInterval] = [:],
                isSignedIn: Bool = false, isDemo: Bool = false) {
        self.globalOffset = globalOffset
        self.trackOffsets = trackOffsets
        self.snapshot = NowPlayingSnapshot(isSignedIn: isSignedIn, isDemo: isDemo)
    }

    public var effectiveOffset: TimeInterval {
        globalOffset + snapshot.trackOffset
    }

    // MARK: Inputs

    /// Clears everything, for example after signing out or switching demo mode.
    public mutating func reset(isSignedIn: Bool, isDemo: Bool) {
        snapshot = NowPlayingSnapshot(isSignedIn: isSignedIn, isDemo: isDemo)
        clock = nil
        lyricsFailedAt = nil
        lastSampleAt = nil
        fastPollUntil = 0
        earlyPollsThisTrack = 0
        consecutiveFailures = 0
    }

    /// Feeds in what Spotify reported, measured at `time` on the monotonic clock.
    public mutating func apply(_ sample: PlaybackSample, at time: TimeInterval) -> [Effect] {
        lastSampleAt = time
        consecutiveFailures = 0
        snapshot.problem = nil

        guard let track = sample.track else {
            let hadTrack = snapshot.track != nil
            clock = nil
            snapshot.track = nil
            snapshot.isPlaying = false
            snapshot.lyrics = .none
            snapshot.currentLine = nil
            snapshot.lyricsChosenByUser = false
            snapshot.trackOffset = 0
            return hadTrack ? [.cancelLyrics] : []
        }

        var effects: [Effect] = []
        if track.id != snapshot.track?.id {
            clock = PlaybackClock(position: sample.position, at: time, isPlaying: sample.isPlaying, duration: track.duration)
            snapshot.track = track
            snapshot.currentLine = nil
            snapshot.lyrics = .loading
            snapshot.lyricsChosenByUser = false
            snapshot.trackOffset = trackOffsets[track.id] ?? 0
            lyricsFailedAt = nil
            earlyPollsThisTrack = 0
            fastPollUntil = time + Self.fastPollWindow
            effects = [.loadLyrics(track), .prefetchUpcoming]
        } else {
            // Same song: metadata such as artwork can arrive later.
            snapshot.track = track
            if clock == nil {
                clock = PlaybackClock(position: sample.position, at: time, isPlaying: sample.isPlaying, duration: track.duration)
            } else if clock?.update(position: sample.position, at: time, isPlaying: sample.isPlaying, duration: track.duration) == true {
                // A pause, resume, seek or repeat: watch closely for a moment.
                fastPollUntil = time + Self.fastPollWindow
                if sample.position < 1 { earlyPollsThisTrack = 0 }
            }
            if case .failed = snapshot.lyrics, let failedAt = lyricsFailedAt, time - failedAt >= lyricsRetryInterval {
                lyricsFailedAt = nil
                snapshot.lyrics = .loading
                effects = [.loadLyrics(track)]
            }
        }
        snapshot.isPlaying = sample.isPlaying
        tick(at: time)
        return effects
    }

    /// A poll failed. Returns how long to wait before polling again.
    public mutating func pollFailed(_ error: Error, at time: TimeInterval) -> TimeInterval {
        if Self.isCancellation(error) {
            return 0
        }
        switch error {
        case SpotifyAPIError.rateLimited(let retryAfter):
            return max(retryAfter, 3)
        case SpotifyAPIError.forbidden:
            snapshot.problem = SpotifyAPIError.forbidden.errorDescription
            return 30
        case SpotifyAPIError.unauthorized, SpotifyAuthError.notSignedIn, SpotifyAuthError.tokenRejected:
            // The sign-in layer takes it from here.
            return 10
        default:
            consecutiveFailures += 1
            snapshot.problem = Self.unreachableMessage
            // 2, 4, 8, 16, 30, 30… seconds. The clock keeps running so lyrics carry on through short drop-outs.
            return min(30, pow(2, Double(min(consecutiveFailures, 5))))
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Lyrics finished loading. Ignored if the song has changed since.
    public mutating func lyricsLoaded(_ lyrics: Lyrics, for trackID: String, chosenByUser: Bool = false, at time: TimeInterval) {
        guard snapshot.track?.id == trackID else { return }
        snapshot.lyrics = .loaded(lyrics)
        snapshot.lyricsChosenByUser = chosenByUser
        lyricsFailedAt = nil
        snapshot.currentLine = nil
        tick(at: time)
    }

    public mutating func lyricsFailed(_ message: String, for trackID: String, at time: TimeInterval) {
        guard snapshot.track?.id == trackID else { return }
        snapshot.lyrics = .failed(message)
        lyricsFailedAt = time
    }

    public mutating func setSignedIn(_ signedIn: Bool) {
        if !signedIn {
            reset(isSignedIn: false, isDemo: snapshot.isDemo)
        } else {
            snapshot.isSignedIn = true
        }
    }

    /// The user did something that may change playback (refresh, opened the app): poll quickly for a bit.
    public mutating func noteUserAction(at time: TimeInterval) {
        fastPollUntil = time + Self.fastPollWindow
    }

    /// Moves the clock right away after the user jumps to a line, before Spotify confirms it.
    public mutating func seekLocally(to position: TimeInterval, at time: TimeInterval) {
        guard let old = clock else { return }
        clock = PlaybackClock(position: position, at: time, isPlaying: old.isPlaying, duration: old.duration)
        fastPollUntil = time + Self.fastPollWindow
        tick(at: time)
    }

    /// Adjusts the timing of the current song only. Returns the new per-song offset.
    @discardableResult
    public mutating func adjustTrackOffset(by delta: TimeInterval, at time: TimeInterval) -> TimeInterval {
        guard let id = snapshot.track?.id else { return 0 }
        let value = ((snapshot.trackOffset + delta) * 20).rounded() / 20
        snapshot.trackOffset = value
        trackOffsets[id] = value == 0 ? nil : value
        tick(at: time)
        return value
    }

    public mutating func resetTrackOffset(at time: TimeInterval) {
        guard let id = snapshot.track?.id else { return }
        snapshot.trackOffset = 0
        trackOffsets[id] = nil
        tick(at: time)
    }

    /// Recomputes the current line. Returns true if it changed.
    @discardableResult
    public mutating func tick(at time: TimeInterval) -> Bool {
        guard let timeline = snapshot.timeline, let position = position(at: time) else { return false }
        let line = timeline.index(at: position)
        guard line != snapshot.currentLine else { return false }
        snapshot.currentLine = line
        return true
    }

    /// True (once per call) when the song should have ended but no new sample
    /// has come in, so the app should poll right away. Capped per track.
    public mutating func takeEarlyPoll(at time: TimeInterval) -> Bool {
        guard let clock, clock.hasReachedEnd(at: time),
              time - (lastSampleAt ?? 0) > 1.5,
              earlyPollsThisTrack < Self.maxEarlyPolls
        else { return false }
        earlyPollsThisTrack += 1
        return true
    }

    // MARK: Queries

    /// The estimated position in the song including the timing offsets.
    public func position(at time: TimeInterval) -> TimeInterval? {
        guard let clock else { return nil }
        return clock.position(at: time) + effectiveOffset
    }

    /// The raw estimated position, without offsets (what Spotify would report).
    public func playbackPosition(at time: TimeInterval) -> TimeInterval? {
        clock?.position(at: time)
    }

    /// The playback position to seek to so that `line` is the current line.
    public func seekPosition(forLine line: Int) -> TimeInterval? {
        guard let timeline = snapshot.timeline, timeline.lines.indices.contains(line) else { return nil }
        // Land just after the line starts so rounding never shows the line before.
        return max(0, timeline.lines[line].time - effectiveOffset + 0.05)
    }

    /// How long to wait before asking Spotify again.
    public func nextPollDelay(at time: TimeInterval) -> TimeInterval {
        guard snapshot.track != nil, let clock else {
            return time < fastPollUntil ? 2 : 6
        }
        var delay: TimeInterval = clock.isPlaying ? 3 : 5
        if time < fastPollUntil {
            delay = min(delay, Self.fastPollInterval)
        }
        // Ask again just after the song should end, to catch the next one quickly.
        if clock.isPlaying, let duration = clock.duration, duration > 0 {
            let remaining = duration - clock.position(at: time)
            delay = min(delay, max(0.75, remaining + 0.4))
        }
        return delay
    }
}
