import Foundation

/// Estimates the playback position between polls of the Spotify Web API.
///
/// Spotify only reports the position when asked, so the clock remembers the
/// last reported position and the moment it was measured, and runs forward
/// from there while the track is playing. Times are in seconds on a monotonic
/// clock (`MonotonicClock.now()` in the app).
///
/// Each sample is a measurement with an error: Spotify read the position at
/// some unknown moment during the request, so a slow request is a vague
/// measurement and a fast one a precise one. The clock keeps a running
/// estimate of its own error and blends each sample in by how precise it is
/// (a one-dimensional Kalman filter), so precise samples quickly win and an
/// unlucky first sample doesn't stick.
public struct PlaybackClock: Equatable, Sendable {
    public private(set) var anchorPosition: TimeInterval
    public private(set) var anchorTime: TimeInterval
    public private(set) var isPlaying: Bool
    public private(set) var duration: TimeInterval?
    /// Variance (seconds²) of the estimate at the anchor.
    public private(set) var anchorVariance: Double
    /// Every sample since the last jump bounds where the music can be: Spotify read the position
    /// during the request, so it lies within ±(uncertainty + floor) of the midpoint. This is the range
    /// of `position - time` that all of them allow, which narrows with each sample. Empty means the
    /// music moved: a slip too small to count as a seek.
    public private(set) var offsetBounds: ClosedRange<Double>
    /// A jump back seen once while playing, waiting for the next answer to agree. Spotify sometimes
    /// answers with a position a second or two old; taking that as a seek would make the lyrics
    /// jump back and forward again. A real backward seek shows one answer later.
    public private(set) var pendingRewind: (position: TimeInterval, time: TimeInterval)?
    /// How far the last blended answer moved the estimate (negative: pulled back). Zero after a jump.
    public private(set) var lastCorrection: TimeInterval = 0

    public static func == (a: PlaybackClock, b: PlaybackClock) -> Bool {
        a.anchorPosition == b.anchorPosition && a.anchorTime == b.anchorTime && a.isPlaying == b.isPlaying
            && a.duration == b.duration && a.anchorVariance == b.anchorVariance && a.offsetBounds == b.offsetBounds
            && a.pendingRewind?.position == b.pendingRewind?.position && a.pendingRewind?.time == b.pendingRewind?.time
            && a.jitterTolerance == b.jitterTolerance && a.lastCorrection == b.lastCorrection
    }

    /// A sample further than this from the prediction (or than its own
    /// uncertainty, if larger) is a real jump: a seek, skip back or repeat.
    public var jitterTolerance: TimeInterval = 0.35
    /// Error that even an instant request has: Spotify's millisecond rounding,
    /// its server's view of a remote device, scheduling on the phone.
    public static let measurementFloor: TimeInterval = 0.02
    /// How much the estimate's variance grows per second of playback (seconds² per second):
    /// the device's clock and Spotify's drift apart a little, so old anchors are trusted less.
    public static let processNoise: Double = 0.005 * 0.005
    /// How fast the bounds widen (seconds per second): the phone's clock and the device's can drift
    /// apart slightly, so old samples bound the music less tightly.
    public static let boundsDrift: Double = 0.002
    /// A jump back to within this many seconds of the start is taken at once.
    public static let restartWindow: TimeInterval = 5

    /// - Parameter uncertainty: half the round trip of the request the position came from.
    public init(position: TimeInterval, at time: TimeInterval, isPlaying: Bool, duration: TimeInterval? = nil,
                uncertainty: TimeInterval = 0) {
        self.anchorPosition = position
        self.anchorTime = time
        self.isPlaying = isPlaying
        self.duration = duration
        self.anchorVariance = Self.variance(uncertainty: uncertainty)
        self.offsetBounds = Self.bounds(position: position, at: time, uncertainty: uncertainty)
    }

    static func bounds(position: TimeInterval, at time: TimeInterval, uncertainty: TimeInterval) -> ClosedRange<Double> {
        let halfWidth = uncertainty + measurementFloor
        return (position - time - halfWidth)...(position - time + halfWidth)
    }

    /// The position was measured at an unknown moment within ±`uncertainty`
    /// of the midpoint, roughly uniformly, which has variance u²/3.
    static func variance(uncertainty: TimeInterval) -> Double {
        uncertainty * uncertainty / 3 + measurementFloor * measurementFloor
    }

    /// The estimated position at `time`, clamped to the track's duration.
    public func position(at time: TimeInterval) -> TimeInterval {
        var position = anchorPosition
        if isPlaying {
            position += max(0, time - anchorTime)
        }
        if let duration {
            position = min(position, duration)
        }
        return max(0, position)
    }

    /// Feeds in a position reported by Spotify.
    ///
    /// - Parameter uncertainty: how far off `time` may be from the moment the
    ///   position was measured (half the request's round trip).
    /// - Returns: true if the clock was re-anchored (a seek, pause, resume or
    ///   repeat), false if the sample agreed with the prediction and was
    ///   blended in.
    @discardableResult
    public mutating func update(position: TimeInterval, at time: TimeInterval, isPlaying: Bool, duration: TimeInterval? = nil,
                                uncertainty: TimeInterval = 0) -> Bool {
        if let duration { self.duration = duration }
        let predicted = self.position(at: time)
        let measurementVariance = Self.variance(uncertainty: uncertainty)
        let threshold = max(jitterTolerance, uncertainty + 2 * (anchorVariance + measurementVariance).squareRoot())
        let rewind = pendingRewind
        pendingRewind = nil
        if isPlaying == self.isPlaying, isPlaying, position < predicted - threshold {
            // Backwards while playing: only once a second answer agrees (see `pendingRewind`).
            // Agrees: the music runs on from there, or it is stuck there (a device that stopped
            // without saying so; see the engine's stall handling).
            let agrees = rewind.map {
                abs($0.position + (time - $0.time) - position) <= threshold || abs($0.position - position) <= threshold
            } ?? false
            // Back to the start is a restart ("Previous" on the steering wheel, repeat-one), not a
            // stale answer: those are a second or two old, never minutes.
            let restart = position < Self.restartWindow
            if !agrees, !restart {
                pendingRewind = (position, time)
                return false
            }
        }
        if isPlaying == self.isPlaying, isPlaying, abs(predicted - position) <= threshold {
            // Blend in, unless the clock sits at the end of the song (the clamp hides how far off it is).
            if self.duration.map({ predicted < $0 }) ?? true {
                // The estimate has aged since the anchor.
                var variance = anchorVariance + Self.processNoise * max(0, time - anchorTime)
                // A sample outside what the earlier ones allow means the music really slipped (a buffering
                // hiccup, a correction on Spotify's side): start again from this sample's bounds and stop
                // trusting the old estimate, so it is fixed now rather than over many polls.
                let innovation = position - predicted
                let aged = max(0, time - anchorTime) * Self.boundsDrift
                let sampleBounds = Self.bounds(position: position, at: time, uncertainty: uncertainty)
                let low = max(offsetBounds.lowerBound - aged, sampleBounds.lowerBound)
                let high = min(offsetBounds.upperBound + aged, sampleBounds.upperBound)
                if low > high {
                    offsetBounds = sampleBounds
                    variance = max(variance, innovation * innovation)
                } else {
                    offsetBounds = low...high
                    if innovation * innovation > 9 * (variance + measurementVariance) {
                        variance = max(variance, innovation * innovation)
                    }
                }
                let gain = variance / (variance + measurementVariance)
                // The blend can't leave the range every sample allows.
                let offset = predicted + gain * innovation - time
                anchorPosition = min(max(offset, offsetBounds.lowerBound), offsetBounds.upperBound) + time
                anchorTime = time
                anchorVariance = variance * measurementVariance / (variance + measurementVariance)
                lastCorrection = anchorPosition - predicted
                // When the samples together pin the music down more tightly than the blend does (several
                // vague samples from both sides), the middle of the range they allow is the better estimate.
                let halfWidth = (offsetBounds.upperBound - offsetBounds.lowerBound) / 2
                if halfWidth * halfWidth / 3 < anchorVariance {
                    anchorPosition = (offsetBounds.lowerBound + offsetBounds.upperBound) / 2 + time
                    anchorVariance = halfWidth * halfWidth / 3
                    lastCorrection = anchorPosition - predicted
                }
                // Never fully certain: leaves room for Spotify's own small drifts.
                anchorVariance += Self.measurementFloor * Self.measurementFloor / 4
            }
            return false
        }
        anchorPosition = position
        anchorTime = time
        anchorVariance = measurementVariance
        offsetBounds = Self.bounds(position: position, at: time, uncertainty: uncertainty)
        lastCorrection = 0
        self.isPlaying = isPlaying
        return true
    }

    /// True once the estimated position has reached the end of the track,
    /// which usually means the next track has started.
    public func hasReachedEnd(at time: TimeInterval) -> Bool {
        guard let duration, isPlaying else { return false }
        return anchorPosition + (time - anchorTime) >= duration
    }
}
