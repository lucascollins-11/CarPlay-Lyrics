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

    /// A sample further than this from the prediction (or than its own
    /// uncertainty, if larger) is a real jump: a seek, skip back or repeat.
    public var jitterTolerance: TimeInterval = 0.35
    /// Error that even an instant request has: Spotify's millisecond rounding,
    /// its server's view of a remote device, scheduling on the phone.
    public static let measurementFloor: TimeInterval = 0.02

    /// - Parameter uncertainty: half the round trip of the request the position came from.
    public init(position: TimeInterval, at time: TimeInterval, isPlaying: Bool, duration: TimeInterval? = nil,
                uncertainty: TimeInterval = 0) {
        self.anchorPosition = position
        self.anchorTime = time
        self.isPlaying = isPlaying
        self.duration = duration
        self.anchorVariance = Self.variance(uncertainty: uncertainty)
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
        if isPlaying == self.isPlaying, isPlaying, abs(predicted - position) <= threshold {
            // Blend in, unless the clock sits at the end of the song (the clamp hides how far off it is).
            if self.duration.map({ predicted < $0 }) ?? true {
                let gain = anchorVariance / (anchorVariance + measurementVariance)
                anchorPosition = predicted + gain * (position - predicted)
                anchorTime = time
                anchorVariance = anchorVariance * measurementVariance / (anchorVariance + measurementVariance)
                // Never fully certain: leaves room for Spotify's own small drifts.
                anchorVariance += Self.measurementFloor * Self.measurementFloor / 4
            }
            return false
        }
        anchorPosition = position
        anchorTime = time
        anchorVariance = measurementVariance
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
