import Foundation

/// Time-synced lyrics with fast lookup of the line for a playback position.
public struct LyricsTimeline: Equatable, Sendable {
    public let lines: [LyricLine]

    public init(lines: [LyricLine]) {
        // Stable sort: lines sharing a timestamp keep their order.
        self.lines = lines.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
    }

    public init(lrc: String) {
        self.init(lines: LRCParser.parse(lrc))
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// Index of the line being sung at `position` seconds, or `nil` before the first line.
    public func index(at position: TimeInterval) -> Int? {
        // Binary search for the last line whose time is <= position.
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= position {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low == 0 ? nil : low - 1
    }

    /// Seconds until the line after `position` starts, or `nil` after the last line.
    public func timeUntilNextLine(after position: TimeInterval) -> TimeInterval? {
        let next = (index(at: position) ?? -1) + 1
        guard next < lines.count else { return nil }
        return lines[next].time - position
    }

    /// A window of lines around `index`, used by small screens such as CarPlay.
    ///
    /// Returns up to `before` lines ahead of the current line, the current line,
    /// and the following lines, `count` lines in total. When `index` is nil
    /// (before the first line), the window starts at the first line.
    public func window(around index: Int?, before: Int, count: Int) -> (range: Range<Int>, current: Int?) {
        guard !lines.isEmpty, count > 0 else { return (0..<0, nil) }
        let anchor = index ?? 0
        // Never let the lines above push the current line out of the window.
        var start = max(0, anchor - min(before, count - 1))
        let end = min(lines.count, start + count)
        // Near the end of the song, pull the window back so it stays full.
        start = max(0, min(start, end - count))
        return (start..<end, index)
    }
}
