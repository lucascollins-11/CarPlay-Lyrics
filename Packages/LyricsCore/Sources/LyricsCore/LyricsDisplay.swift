import Foundation

/// One row on a small lyrics screen (a CarPlay list row).
public struct LyricsRow: Equatable, Sendable {
    public var text: String
    public var detail: String?
    public var isCurrent: Bool
    /// The synced line this row shows, if any.
    public var lineIndex: Int?

    public init(text: String, detail: String? = nil, isCurrent: Bool = false, lineIndex: Int? = nil) {
        self.text = text
        self.detail = detail
        self.isCurrent = isCurrent
        self.lineIndex = lineIndex
    }
}

/// What a small screen such as CarPlay should show for a snapshot.
///
/// Wording follows Apple's CarPlay guidelines: messages state the condition
/// and never ask the driver to pick up their iPhone.
public enum LyricsDisplay: Equatable, Sendable {
    /// An empty screen with a short message.
    case message(title: String, subtitle: String?)
    /// A header (song and artist) and rows of lyrics.
    case rows(header: String, rows: [LyricsRow])

    public static let instrumentalText = "♪ Instrumental ♪"
    public static let gapText = "♪"

    public static func make(for snapshot: NowPlayingSnapshot, maxRows: Int, linesBefore: Int = 1, wrapLimit: Int = 34) -> LyricsDisplay {
        guard snapshot.isSignedIn || snapshot.isDemo else {
            return .message(title: "Spotify isn't connected", subtitle: "Connect Spotify in Lyrics before your next drive.")
        }
        guard let track = snapshot.track else {
            if snapshot.problem != nil {
                return .message(title: "Can't reach Spotify", subtitle: "Lyrics will appear when the connection is back.")
            }
            if let away = snapshot.notASongText {
                return .message(title: away.title, subtitle: away.subtitle)
            }
            return .message(title: "Nothing playing", subtitle: "Play a song on Spotify to see its lyrics.")
        }
        let header = track.artistLine.isEmpty ? track.title : "\(track.title) · \(track.artistLine)"
        let rowLimit = max(1, maxRows)

        func single(_ text: String, _ detail: String? = nil) -> LyricsDisplay {
            .rows(header: header, rows: [LyricsRow(text: text, detail: detail)])
        }

        switch snapshot.lyrics {
        case .none, .loading:
            return single("Finding lyrics…")
        case .failed:
            return single("Lyrics unavailable right now", "Trying again shortly")
        case .loaded(.notFound):
            return single("No lyrics for this song")
        case .loaded(.instrumental):
            return single(instrumentalText)
        case .loaded(.plain(let lines)):
            let rows = lines.filter { !$0.isEmpty }.prefix(rowLimit).map { line -> LyricsRow in
                let (first, rest) = LineSplitter.split(line, limit: wrapLimit)
                return LyricsRow(text: first, detail: rest)
            }
            return .rows(header: "\(header) · not synced", rows: Array(rows))
        case .loaded(.synced(let timeline)):
            var rows: [LyricsRow] = []
            if snapshot.currentLine == nil {
                // Before the first line: a waiting marker, then what's coming.
                rows.append(LyricsRow(text: gapText, isCurrent: true))
            }
            let window = timeline.window(around: snapshot.currentLine, before: linesBefore, count: rowLimit)
            for index in window.range where rows.count < rowLimit {
                let line = timeline.lines[index]
                let (first, rest) = LineSplitter.split(line.isGap ? gapText : line.text, limit: wrapLimit)
                rows.append(LyricsRow(text: first, detail: rest, isCurrent: index == snapshot.currentLine, lineIndex: index))
            }
            return .rows(header: header, rows: rows)
        }
    }
}

/// The current and next lyric line, for the Live Activity on the Lock Screen,
/// Dynamic Island and CarPlay Dashboard.
public struct LiveLyricsContent: Codable, Hashable, Sendable {
    public var title: String
    public var artist: String
    public var current: String
    public var next: String?
    public var isPlaying: Bool
    /// Seconds into the song when this content was produced.
    public var position: Double
    public var duration: Double

    public init(title: String, artist: String, current: String, next: String?, isPlaying: Bool, position: Double, duration: Double) {
        self.title = title
        self.artist = artist
        self.current = current
        self.next = next
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
    }

    public static let idle = LiveLyricsContent(title: "Lyrics", artist: "", current: "Nothing playing", next: nil,
                                               isPlaying: false, position: 0, duration: 0)

    public static func make(for snapshot: NowPlayingSnapshot, position: TimeInterval?) -> LiveLyricsContent {
        guard let track = snapshot.track else {
            if !(snapshot.isSignedIn || snapshot.isDemo) {
                return LiveLyricsContent(title: "Lyrics", artist: "", current: "Spotify isn't connected", next: nil,
                                         isPlaying: false, position: 0, duration: 0)
            }
            if let away = snapshot.notASongText {
                return LiveLyricsContent(title: "Lyrics", artist: "", current: away.title, next: nil,
                                         isPlaying: false, position: 0, duration: 0)
            }
            return .idle
        }
        var current: String
        var next: String?
        switch snapshot.lyrics {
        case .none, .loading:
            current = "Finding lyrics…"
        case .failed:
            current = "Lyrics unavailable right now"
        case .loaded(.notFound):
            current = "No lyrics for this song"
        case .loaded(.instrumental):
            current = LyricsDisplay.instrumentalText
        case .loaded(.plain(let lines)):
            current = lines.first { !$0.isEmpty } ?? "No lyrics for this song"
            next = "Lyrics not synced"
        case .loaded(.synced(let timeline)):
            if let index = snapshot.currentLine {
                let line = timeline.lines[index]
                current = line.isGap ? LyricsDisplay.gapText : line.text
                next = timeline.lines.dropFirst(index + 1).first { !$0.isGap }?.text
            } else {
                current = LyricsDisplay.gapText
                next = timeline.lines.first { !$0.isGap }?.text
            }
        }
        if !snapshot.isPlaying, case .loaded = snapshot.lyrics {
            current = "Paused · " + current
        }
        return LiveLyricsContent(title: track.title, artist: track.artistLine, current: current, next: next,
                                 isPlaying: snapshot.isPlaying, position: position ?? 0, duration: track.duration)
    }

    /// Two contents show the same text (position changes alone don't need a Live Activity update).
    public func showsSameText(as other: LiveLyricsContent) -> Bool {
        title == other.title && artist == other.artist && current == other.current && next == other.next && isPlaying == other.isPlaying
    }
}

public enum LineSplitter {
    /// Splits `text` at a word boundary at or before `limit` characters.
    /// A single word longer than the limit stays whole.
    public static func split(_ text: String, limit: Int) -> (String, String?) {
        guard text.count > limit else { return (text, nil) }
        let words = text.split(separator: " ")
        var first = ""
        var index = 0
        while index < words.count {
            let candidate = first.isEmpty ? String(words[index]) : first + " " + String(words[index])
            if candidate.count > limit, !first.isEmpty { break }
            first = candidate
            index += 1
        }
        let rest = words[index...].joined(separator: " ")
        return (first, rest.isEmpty ? nil : rest)
    }
}

extension NowPlayingSnapshot {
    /// What to say while Spotify plays something that has no lyrics here (EC36).
    public var notASongText: (title: String, subtitle: String)? {
        switch playingKind {
        case .episode: return ("Spotify is playing a podcast", "Lyrics show for songs.")
        case .ad: return ("Spotify is playing an ad", "Lyrics come back with the next song.")
        case .unknown: return ("Spotify isn't sharing what's playing", "A Private Session or some local files hide the song.")
        case .nothing, .track: return nil
        }
    }
}
