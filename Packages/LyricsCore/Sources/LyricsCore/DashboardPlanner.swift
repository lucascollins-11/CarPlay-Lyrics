import Foundation

/// Decides what the Live Activity (CarPlay Dashboard, Lock Screen) shows and
/// when to send it. Kept free of ActivityKit so it can be tested.
///
/// - Lead: a Live Activity update takes a moment to appear, so lines are
///   chosen and sent `lead` seconds early and land on time.
/// - Updates are at least `minimumUpdateInterval` apart. A line shorter than
///   `shortLine` is shown together with the next one, so fast lines aren't
///   skipped or flashed past the driver.
/// - After a long pause it shows a neutral "Spotify paused" instead of an old line.
/// - While playing it re-sends at least every `refreshInterval`, so iOS doesn't
///   mark the activity stale.
public struct DashboardPlanner: Sendable {
    public var lead: TimeInterval
    public static let minimumUpdateInterval: TimeInterval = 0.4
    public static let shortLine: TimeInterval = 1.2
    public static let longPause: TimeInterval = 120
    public static let refreshInterval: TimeInterval = 30
    public static let pausedText = "Spotify paused"

    public private(set) var lastSent: LiveLyricsContent?
    public private(set) var lastSentAt: TimeInterval?
    private var pausedSince: TimeInterval?

    public init(lead: TimeInterval = 0.3) {
        self.lead = lead
    }

    public struct Plan: Equatable, Sendable {
        /// Content to send now, if anything changed.
        public var send: LiveLyricsContent?
        /// Check again after this many seconds (sooner if the snapshot changes).
        public var wakeAfter: TimeInterval
    }

    /// - Parameters:
    ///   - position: the song position now, including timing offsets (`NowPlayingEngine.position(at:)`).
    ///   - now: monotonic seconds.
    public mutating func plan(snapshot: NowPlayingSnapshot, position: TimeInterval?, now: TimeInterval) -> Plan {
        if snapshot.isPlaying || snapshot.track == nil {
            pausedSince = nil
        } else if pausedSince == nil {
            pausedSince = now
        }

        let content = self.content(for: snapshot, position: position, now: now)
        let sinceLastSend = lastSentAt.map { now - $0 } ?? .infinity
        let changed = !(lastSent.map { $0.showsSameText(as: content) } ?? false)
        let needsRefresh = snapshot.isPlaying && sinceLastSend >= Self.refreshInterval

        var plan = Plan(send: nil, wakeAfter: Self.refreshInterval)
        if changed || needsRefresh {
            if sinceLastSend < Self.minimumUpdateInterval {
                // Too soon after the last update: come back when allowed, and send whatever is current then.
                return Plan(send: nil, wakeAfter: Self.minimumUpdateInterval - sinceLastSend)
            }
            lastSent = content
            lastSentAt = now
            plan.send = content
        }

        // Wake for the next line (sent `lead` early), the long-pause switch, or the refresh.
        var wake = snapshot.isPlaying ? Self.refreshInterval : Self.longPause
        if snapshot.isPlaying, let timeline = snapshot.timeline, let position,
           let untilNext = timeline.timeUntilNextLine(after: position + lead) {
            wake = min(wake, untilNext + 0.01)
        }
        if let pausedSince, now - pausedSince < Self.longPause {
            wake = min(wake, Self.longPause - (now - pausedSince) + 0.01)
        }
        plan.wakeAfter = max(0.02, wake)
        return plan
    }

    func content(for snapshot: NowPlayingSnapshot, position: TimeInterval?, now: TimeInterval) -> LiveLyricsContent {
        var shown = snapshot
        // Only a playing song is shown ahead; a paused one shows where it stopped.
        let shownPosition = snapshot.isPlaying ? position.map { $0 + lead } : position
        if let timeline = snapshot.timeline, let shownPosition {
            shown.currentLine = timeline.index(at: shownPosition)
        }
        var content = LiveLyricsContent.make(for: shown, position: shownPosition)

        if let pausedSince, now - pausedSince >= Self.longPause, let track = snapshot.track {
            // Probably switched to the radio or another app: don't leave an old lyric up all drive.
            return LiveLyricsContent(title: track.title, artist: track.artistLine, current: Self.pausedText, next: nil,
                                     isPlaying: false, position: content.position, duration: track.duration)
        }

        // A very short line is shown together with its neighbour, so it isn't skipped or flashed:
        // with the next line while it plays, and still next to it while that next line plays.
        if snapshot.isPlaying, let timeline = shown.timeline, let index = shown.currentLine {
            let lines = timeline.lines
            func isShort(_ i: Int) -> Bool {
                i >= 0 && lines.indices.contains(i + 1) && !lines[i].isGap && !lines[i + 1].isGap
                    && lines[i + 1].time - lines[i].time < Self.shortLine
            }
            let first: Int? = isShort(index - 1) ? index - 1 : (isShort(index) ? index : nil)
            if let first {
                content.current = lines[first].text + " / " + lines[first + 1].text
                content.next = lines.dropFirst(first + 2).first { !$0.isGap }?.text
            }
        }
        return content
    }
}
