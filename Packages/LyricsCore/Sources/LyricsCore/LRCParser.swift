import Foundation

/// One time-stamped line of lyrics.
public struct LyricLine: Equatable, Hashable, Sendable {
    /// Seconds from the start of the track at which this line begins.
    public var time: TimeInterval
    /// The text of the line. Empty for an instrumental gap.
    public var text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }

    /// True when the line has no words (an instrumental break in LRC files).
    public var isGap: Bool { text.isEmpty }
}

/// Parses LRC formatted lyrics, as returned by LRCLIB's `syncedLyrics` field.
///
/// Supported:
/// - `[mm:ss]`, `[mm:ss.x]`, `[mm:ss.xx]`, `[mm:ss.xxx]` and `[mm:ss:xx]` time tags,
///   and `[hh:mm:ss.xx]` for long tracks (a fraction after the third field marks hours)
/// - Windows (`\r\n`) and old Mac (`\r`) line endings
/// - a leading byte order mark, which would otherwise hide the first line's time tag
/// - several time tags on one line (`[00:10.00][00:42.00]Chorus`)
/// - the `[offset:±ms]` tag (a positive offset shows lyrics earlier)
/// - enhanced/word-level tags (`<00:10.50>`), which are stripped
/// - metadata tags such as `[ar:...]`, which are ignored
public enum LRCParser {
    public static func parse(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0

        var text = normalizeLineEndings(lrc)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        for rawLine in text.components(separatedBy: .newlines) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [TimeInterval] = []

            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseTimestamp(tag) {
                    times.append(time)
                } else if let value = metadataValue(tag, key: "offset"), let ms = Double(value) {
                    offset = ms / 1000
                }
                rest = rest[rest.index(after: close)...]
            }

            guard !times.isEmpty else { continue }
            let text = stripWordTags(String(rest)).trimmingCharacters(in: .whitespaces)
            for time in times {
                lines.append(LyricLine(time: time, text: text))
            }
        }

        if offset != 0 {
            lines = lines.map { LyricLine(time: max(0, $0.time - offset), text: $0.text) }
        }
        // Stable sort so lines that share a timestamp keep file order.
        return lines.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
    }

    /// Turns `\r\n` and lone `\r` into `\n`, so splitting on newlines never yields extra blank lines.
    public static func normalizeLineEndings(_ text: String) -> String {
        // Check scalars: "\r\n" is a single Character, so String.contains("\r") misses it.
        guard text.unicodeScalars.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Parses `mm:ss`, `mm:ss.fff`, `mm:ss:ff` or `hh:mm:ss.ff` into seconds.
    static func parseTimestamp<S: StringProtocol>(_ tag: S) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 || parts.count == 3 else { return nil }

        var hours = 0
        var minutesPart = parts[0]
        var secondsPart = parts[1]
        if parts.count == 3 {
            if parts[2].contains(".") {
                // `hh:mm:ss.xx`: only a fraction in the last field tells it apart from `mm:ss:xx`.
                guard let h = Int(parts[0]), h >= 0, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
                hours = h
                minutesPart = parts[1]
                secondsPart = parts[2]
            } else {
                // `mm:ss:xx` uses a colon before the hundredths.
                secondsPart += "." + parts[2]
            }
        }
        guard let minutes = Int(minutesPart), minutes >= 0 else { return nil }
        guard !secondsPart.isEmpty,
              secondsPart.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let seconds = Double(secondsPart), seconds >= 0
        else { return nil }
        return TimeInterval(hours) * 3600 + TimeInterval(minutes) * 60 + seconds
    }

    private static func metadataValue<S: StringProtocol>(_ tag: S, key: String) -> String? {
        guard let colon = tag.firstIndex(of: ":") else { return nil }
        let name = tag[tag.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard name == key else { return nil }
        return tag[tag.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    private static func stripWordTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">"),
               parseTimestamp(text[text.index(after: index)..<close]) != nil {
                index = text.index(after: close)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result.replacingOccurrences(of: "  ", with: " ")
    }
}
