import Foundation

/// Estimates the playback position between polls of the Spotify Web API.
///
/// Spotify only reports the position when asked, so the clock remembers the
/// last reported position and the moment it was measured, and runs forward
/// from there while the track is playing. Times are in seconds on a monotonic
/// clock (for example `ProcessInfo.processInfo.systemUptime`).
public struct PlaybackClock: Equatable, Sendable {
    public private(set) var anchorPosition: TimeInterval
    public private(set) var anchorTime: TimeInterval
    public private(set) var isPlaying: Bool
    public private(set) var duration: TimeInterval?

    /// A new sample within this many seconds of the prediction is treated as
    /// jitter and ignored, so the highlighted line does not flicker.
    public var jitterTolerance: TimeInterval = 0.35

    public init(position: TimeInterval, at time: TimeInterval, isPlaying: Bool, duration: TimeInterval? = nil) {
        self.anchorPosition = position
        self.anchorTime = time
        self.isPlaying = isPlaying
        self.duration = duration
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
    /// - Returns: true if the clock was re-anchored, false if the sample
    ///   agreed with the prediction and was ignored.
    @discardableResult
    public mutating func update(position: TimeInterval, at time: TimeInterval, isPlaying: Bool, duration: TimeInterval? = nil) -> Bool {
        if let duration { self.duration = duration }
        let predicted = self.position(at: time)
        if isPlaying == self.isPlaying, isPlaying, abs(predicted - position) <= jitterTolerance {
            return false
        }
        anchorPosition = position
        anchorTime = time
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
