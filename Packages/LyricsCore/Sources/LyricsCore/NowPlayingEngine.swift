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
    public static let unexpectedAnswerMessage = "Spotify sent an answer this app doesn't understand. Retrying…"

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
    private var consecutiveUnauthorized = 0
    private var slowPollingUntil: TimeInterval = 0
    /// Spotify briefly answers "nothing playing" around skips and device hand-offs.
    private var emptySamplesInARow = 0
    private var lastTrackSampleAt: TimeInterval?
    /// Clear the song only after this many empty answers in a row, or this long without a song.
    public static let emptySamplesToClear = 2
    public static let emptyTimeToClear: TimeInterval = 5
    /// A Retry-After longer than this is shown to the user.
    public static let longRateLimit: TimeInterval = 30
    /// Longest wait after a request that didn't get through (no signal, timeout).
    public static let maxTransportBackoff: TimeInterval = 8
    /// The last position Spotify reported while saying it was playing, to notice a frozen position.
    private var lastPlayingPosition: TimeInterval?
    private var lastPlayingAt: TimeInterval?
    /// How many "playing" samples in a row repeated that position, and when it was first seen.
    private var repeatCount = 0
    private var repeatSince: TimeInterval?
    /// Spotify says it is playing but the position stopped moving (the playing device went offline).
    public private(set) var isStalled = false

    /// After a change (new song, pause, seek), poll quickly for this long to catch follow-up changes.
    public static let fastPollWindow: TimeInterval = 5
    public static let fastPollInterval: TimeInterval = 1
    /// Steady polling while a song plays. A skip, pause or seek made in the car only shows up at
    /// the next poll, so this sets how quickly the lyrics follow (at most this plus the round trip).
    public static let playingPollInterval: TimeInterval = 1.5
    public static let pausedPollInterval: TimeInterval = 5
    /// After Spotify said "slow down" (429), poll a song this often for `rateLimitCooldown`.
    public static let rateLimitedPollInterval: TimeInterval = 3
    public static let rateLimitCooldown: TimeInterval = 120
    /// How many times to re-poll early while a song sits at its end.
    public static let maxEarlyPolls = 4
    /// The line only moves back if the position is this far before the current line's start.
    public static let backwardHysteresis: TimeInterval = 0.3
    /// Consecutive 401s, after a forced token refresh each, before asking the user to sign in again.
    public static let maxUnauthorized = 3
    /// Spotify can answer back-to-back requests with the same cached position, so a stall
    /// needs this many repeats in a row, spanning at least `stallMinimumSpan`.
    /// Long enough that a weak-signal hiccup in Spotify's own state (while the
    /// phone keeps playing buffered audio) doesn't freeze the lyrics.
    static let stallMinimumRepeats = 2
    static let stallMinimumSpan: TimeInterval = 10
    static let stallPositionTolerance: TimeInterval = 0.05

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
        consecutiveUnauthorized = 0
        lastPlayingPosition = nil
        lastPlayingAt = nil
        repeatCount = 0
        repeatSince = nil
        isStalled = false
        emptySamplesInARow = 0
        lastTrackSampleAt = nil
        slowPollingUntil = 0
    }

    /// True while Spotify's rate limit is in force; skip optional requests such as prefetching.
    public func isRateLimited(at time: TimeInterval) -> Bool {
        time < slowPollingUntil
    }

    /// The network came back: forget the backoff so the next poll goes out now.
    public mutating func networkRestored(at time: TimeInterval) {
        consecutiveFailures = 0
        fastPollUntil = time + Self.fastPollWindow
    }

    /// True after Spotify kept rejecting the token even right after a refresh.
    /// The app should sign out so the sign-in screen comes back.
    public var needsSignIn: Bool {
        consecutiveUnauthorized >= Self.maxUnauthorized
    }

    /// Feeds in what Spotify reported, measured at `time` on the monotonic clock.
    /// - Parameter uncertainty: half the request's round trip; `time` is the request's midpoint.
    public mutating func apply(_ sample: PlaybackSample, at time: TimeInterval, uncertainty: TimeInterval = 0) -> [Effect] {
        lastSampleAt = time
        consecutiveFailures = 0
        consecutiveUnauthorized = 0
        snapshot.problem = nil

        guard let track = sample.track else {
            let hadTrack = snapshot.track != nil
            emptySamplesInARow += 1
            if hadTrack, emptySamplesInARow < Self.emptySamplesToClear,
               time - (lastTrackSampleAt ?? time) < Self.emptyTimeToClear {
                // Probably a blip around a skip: keep the song and its clock for now, and look again soon.
                fastPollUntil = time + Self.fastPollWindow
                return []
            }
            clock = nil
            snapshot.track = nil
            snapshot.isPlaying = false
            snapshot.lyrics = .none
            snapshot.currentLine = nil
            snapshot.lyricsChosenByUser = false
            snapshot.trackOffset = 0
            isStalled = false
            lastPlayingPosition = nil
            lastPlayingAt = nil
            repeatCount = 0
            repeatSince = nil
            return hadTrack ? [.cancelLyrics] : []
        }

        emptySamplesInARow = 0
        lastTrackSampleAt = time
        var effects: [Effect] = []
        if track.id != snapshot.track?.id {
            clock = PlaybackClock(position: sample.position, at: time, isPlaying: sample.isPlaying, duration: track.duration,
                                  uncertainty: uncertainty)
            snapshot.track = track
            snapshot.currentLine = nil
            snapshot.lyrics = .loading
            snapshot.lyricsChosenByUser = false
            snapshot.trackOffset = trackOffsets[track.id] ?? 0
            lyricsFailedAt = nil
            earlyPollsThisTrack = 0
            isStalled = false
            repeatCount = 0
            repeatSince = nil
            fastPollUntil = time + Self.fastPollWindow
            effects = [.loadLyrics(track), .prefetchUpcoming]
        } else {
            // Same song: metadata such as artwork can arrive later.
            snapshot.track = track
            let isRepeat = sample.isPlaying && isRepeatOfLastPosition(sample.position)
            if isRepeat {
                repeatCount += 1
                repeatSince = repeatSince ?? lastPlayingAt
            } else {
                repeatCount = 0
                repeatSince = nil
            }
            if isRepeat {
                // Spotify says "playing" but the position hasn't moved. Once or briefly, that's a
                // cached answer: keep the clock running and don't re-anchor backwards. If it
                // persists, the playing device went offline: hold the line where it is (never
                // jump back) and poll at the normal pace until it moves again.
                if !isStalled, clock?.pendingRewind != nil {
                    // The answer before was a jump back, and this one says the same: the device
                    // stopped there. Go back to it once (the clock confirms the rewind).
                    clock?.update(position: sample.position, at: time, isPlaying: true, duration: track.duration,
                                  uncertainty: uncertainty)
                }
                if !isStalled, repeatCount >= Self.stallMinimumRepeats, let since = repeatSince,
                   time - since >= Self.stallMinimumSpan, let current = clock?.position(at: time) {
                    clock = PlaybackClock(position: current, at: time, isPlaying: false, duration: track.duration)
                    isStalled = true
                }
            } else if clock == nil {
                isStalled = false
                clock = PlaybackClock(position: sample.position, at: time, isPlaying: sample.isPlaying, duration: track.duration,
                                  uncertainty: uncertainty)
            } else if isStalled {
                // Moving again: follow Spotify from here.
                isStalled = false
                clock = PlaybackClock(position: sample.position, at: time, isPlaying: sample.isPlaying, duration: track.duration,
                                  uncertainty: uncertainty)
                fastPollUntil = time + Self.fastPollWindow
            } else if clock?.update(position: sample.position, at: time, isPlaying: sample.isPlaying, duration: track.duration,
                                    uncertainty: uncertainty) == true {
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
        if sample.isPlaying {
            lastPlayingPosition = sample.position
            lastPlayingAt = time
        } else {
            lastPlayingPosition = nil
            lastPlayingAt = nil
        }
        snapshot.isPlaying = sample.isPlaying && !isStalled
        tick(at: time)
        return effects
    }

    private func isRepeatOfLastPosition(_ position: TimeInterval) -> Bool {
        guard let lastPosition = lastPlayingPosition else { return false }
        return abs(position - lastPosition) <= Self.stallPositionTolerance
    }

    /// A poll failed. Returns how long to wait before polling again.
    public mutating func pollFailed(_ error: Error, at time: TimeInterval) -> TimeInterval {
        if Self.isCancellation(error) {
            return 0
        }
        switch error {
        case SpotifyAPIError.rateLimited(let retryAfter):
            // Honour Retry-After: asking sooner only gets more 429s. The clock keeps the current song going.
            slowPollingUntil = time + max(Self.rateLimitCooldown, retryAfter)
            if retryAfter > Self.longRateLimit {
                let minutes = Int((retryAfter / 60).rounded(.up))
                snapshot.problem = "Spotify asked this app to wait \(minutes) min. Song changes will show after that."
            }
            return max(retryAfter, 3)
        case SpotifyAPIError.forbidden:
            snapshot.problem = SpotifyAPIError.forbidden.errorDescription
            return 30
        case SpotifyAPIError.unauthorized:
            // Rejected even after a fresh token: after a few in a row, the app signs out (see needsSignIn).
            consecutiveUnauthorized += 1
            return 10
        case SpotifyAuthError.notSignedIn, SpotifyAuthError.tokenRejected:
            // The sign-in layer takes it from here.
            return 10
        case is DecodingError:
            consecutiveFailures += 1
            snapshot.problem = Self.unexpectedAnswerMessage
            return min(30, pow(2, Double(min(consecutiveFailures, 5))))
        default:
            consecutiveFailures += 1
            snapshot.problem = Self.unreachableMessage
            // 2, 4, 8, 8… seconds. The clock keeps running so lyrics carry on through short drop-outs.
            // Kept short because the app only polls while something shows lyrics, and in a dead zone
            // the phone still reports a network (so no "network is back" signal comes): the next
            // working poll must not be far off once the car is out of it.
            return min(Self.maxTransportBackoff, pow(2, Double(min(consecutiveFailures, 5))))
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
        // A small correction of the clock must not flash the previous line back for a moment.
        // Real jumps back (seeks, repeats, offset changes) move further than this and still apply.
        if let current = snapshot.currentLine, (line ?? -1) < current, clock?.isPlaying == true,
           position > timeline.lines[current].time - Self.backwardHysteresis {
            return false
        }
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

    /// How long the app can sleep before the highlighted line may change. Sleeps
    /// until just after the next line starts, and never more than a second, so
    /// the end-of-song check still runs. Saves waking the CPU 10 times a second.
    public func nextTickDelay(at time: TimeInterval) -> TimeInterval {
        guard let clock, clock.isPlaying, let timeline = snapshot.timeline, let position = position(at: time),
              let wait = timeline.timeUntilNextLine(after: position)
        else { return 1 }
        return min(1, max(0.02, wait + 0.01))
    }

    /// How long to wait before asking Spotify again.
    public func nextPollDelay(at time: TimeInterval) -> TimeInterval {
        guard snapshot.track != nil, let clock else {
            return time < fastPollUntil ? 2 : 6
        }
        let playingInterval = time < slowPollingUntil ? Self.rateLimitedPollInterval : Self.playingPollInterval
        // A stalled device shows as paused, but its return should be noticed as fast as a skip.
        var delay: TimeInterval = clock.isPlaying || isStalled ? playingInterval : Self.pausedPollInterval
        if time < fastPollUntil {
            delay = min(delay, Self.fastPollInterval)
        }
        // Ask again just after the song should end, to catch the next one quickly. Once the clock
        // sits at the end, only the capped early polls (takeEarlyPoll) hurry things along.
        if clock.isPlaying, let duration = clock.duration, duration > 0, earlyPollsThisTrack < Self.maxEarlyPolls {
            let remaining = duration - clock.position(at: time)
            if remaining > 0 {
                delay = min(delay, max(0.75, remaining + 0.4))
            }
        }
        return delay
    }
}
