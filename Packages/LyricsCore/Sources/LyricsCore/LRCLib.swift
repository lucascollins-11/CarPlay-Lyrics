import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A lyrics record from LRCLIB (https://lrclib.net/docs).
public struct LRCLibRecord: Codable, Equatable, Sendable {
    public var id: Int
    public var trackName: String?
    public var artistName: String?
    public var albumName: String?
    /// Track length in seconds.
    public var duration: Double?
    public var instrumental: Bool?
    public var plainLyrics: String?
    public var syncedLyrics: String?

    public init(id: Int, trackName: String? = nil, artistName: String? = nil, albumName: String? = nil,
                duration: Double? = nil, instrumental: Bool? = nil, plainLyrics: String? = nil, syncedLyrics: String? = nil) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }

    public var hasSyncedLyrics: Bool { !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasPlainLyrics: Bool { !(plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The lyrics the app can show for a track.
public enum Lyrics: Equatable, Sendable {
    case synced(LyricsTimeline)
    case plain([String])
    case instrumental
    case notFound

    /// - Parameter trackDuration: the song's length, used to spot timestamps that run past
    ///   its end when the record doesn't say how long it is.
    public init(record: LRCLibRecord?, trackDuration: TimeInterval? = nil) {
        guard let record else { self = .notFound; return }
        var degenerate: LyricsTimeline?
        if record.hasSyncedLyrics, let lrc = record.syncedLyrics {
            let timeline = LyricsTimeline(lrc: lrc)
            if !timeline.isEmpty {
                if !timeline.hasUnusableTiming(duration: record.duration ?? trackDuration) {
                    self = .synced(timeline)
                    return
                }
                degenerate = timeline
            }
        }
        if record.hasPlainLyrics, let plain = record.plainLyrics {
            self = .plain(LRCParser.normalizeLineEndings(plain).components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) })
        } else if let degenerate, case let words = degenerate.lines.filter({ !$0.isGap }).map(\.text), !words.isEmpty {
            // Timestamps are junk but the words are fine: show them unsynced rather than wrong.
            self = .plain(words)
        } else if record.instrumental == true {
            self = .instrumental
        } else {
            self = .notFound
        }
    }

    public var isSynced: Bool {
        if case .synced = self { return true }
        return false
    }
}

extension LyricsTimeline {
    /// True when following these timestamps would show the wrong line for much of the song:
    /// most lines share one timestamp (often every line at `[00:00.00]`), or lines start
    /// after the song has ended (timings from a longer cut).
    public func hasUnusableTiming(duration: TimeInterval?) -> Bool {
        let sung = lines.filter { !$0.isGap }
        if sung.count >= 3 {
            var counts: [TimeInterval: Int] = [:]
            for line in sung { counts[line.time, default: 0] += 1 }
            if let most = counts.values.max(), most * 2 > sung.count { return true }
        }
        if let duration, duration > 0, let last = sung.last ?? lines.last, last.time > duration + 2 {
            return true
        }
        return false
    }
}

/// Cleans Spotify titles so they match LRCLIB's catalogue.
public enum TitleNormalizer {
    /// Removes suffixes such as " - Remastered 2011", " - Radio Edit",
    /// "(feat. X)" and "[Live]" that LRCLIB entries usually leave out.
    public static func simplify(_ title: String) -> String {
        var result = title
        // " - Remastered 2009", " - Live at ...", " - From \"Film\""
        if let dash = result.range(of: " - ") {
            result = String(result[..<dash.lowerBound])
        }
        // "(feat. X)", "(with X)", "[Remix]", "(Remastered)"
        let patterns = [
            #"\s*[\(\[](feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]"#,
            #"\s*[\(\[][^\)\]]*(remaster|version|edit|mix|live|mono|stereo|deluxe|bonus)[^\)\]]*[\)\]]"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? title : result
    }

    /// Lowercased, punctuation-free form used to compare titles.
    public static func comparable(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// Client for the free LRCLIB lyrics API.
public struct LRCLibClient: Sendable {
    public var baseURL: URL
    public var userAgent: String
    public var http: HTTPClient

    public init(baseURL: URL = URL(string: "https://lrclib.net")!,
                userAgent: String = "CarPlayLyrics/1.0 (personal iOS app)",
                http: HTTPClient = URLSession.shared) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.http = http
    }

    /// Finds the best lyrics for a track.
    ///
    /// Tries an exact signature match first (`/api/get`, which LRCLIB matches
    /// within ±2 seconds of the duration), then the simplified title, then a
    /// search ranked by `bestMatch`. Each step falls through on errors; this
    /// throws only if every step failed and nothing at all was found.
    public func lyrics(for track: NowPlayingTrack) async throws -> LRCLibRecord? {
        let simplified = TitleNormalizer.simplify(track.title)
        var fallback: LRCLibRecord?
        var lastError: Error?

        func consider(_ record: LRCLibRecord?) -> LRCLibRecord? {
            guard let record, Self.durationMatches(record, track) else { return nil }
            if Lyrics(record: record, trackDuration: track.duration).isSynced { return record }
            // Keep the first plain/instrumental hit in case nothing synced turns up.
            if fallback == nil, record.hasPlainLyrics || record.instrumental == true { fallback = record }
            return nil
        }

        do {
            if let found = consider(try await get(title: track.title, artist: track.primaryArtist, album: track.album, duration: track.duration)) {
                return found
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
        }

        if simplified != track.title {
            do {
                if let found = consider(try await get(title: simplified, artist: track.primaryArtist, album: track.album, duration: track.duration)) {
                    return found
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        // A synced search hit ends the lookup. Otherwise try free-text search, which matches
        // artists spelled differently (romanized names, "A & B" vs "A, B", featured artists).
        var results: [LRCLibRecord] = []
        var titleSearchWorked = false
        do {
            results = try await search(title: simplified, artist: track.primaryArtist)
            titleSearchWorked = true
            if let best = Self.bestMatch(in: results, for: track) {
                if Self.isSynced(best, for: track) { return best }
                // The song itself is on LRCLIB, just without synced lyrics: a looser search won't do better.
                if Self.hasExactTitle(best, for: track) { return best }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
        }

        do {
            results += try await search(query: "\(simplified) \(track.primaryArtist)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !titleSearchWorked { lastError = error }
        }
        // Only a working title search makes "nothing found" an answer. If it failed (offline),
        // a miss here must stay an error so the lookup is retried instead of remembered.
        if titleSearchWorked { lastError = nil }
        if let best = Self.bestMatch(in: results, for: track), Self.isSynced(best, for: track) || fallback == nil {
            return best
        }

        if let fallback { return fallback }
        if let lastError { throw lastError }
        return nil
    }

    static func hasExactTitle(_ record: LRCLibRecord, for track: NowPlayingTrack) -> Bool {
        TitleNormalizer.comparable(TitleNormalizer.simplify(record.trackName ?? ""))
            == TitleNormalizer.comparable(TitleNormalizer.simplify(track.title))
    }

    static func isSynced(_ record: LRCLibRecord, for track: NowPlayingTrack) -> Bool {
        Lyrics(record: record, trackDuration: track.duration).isSynced
    }

    /// LRCLIB's signature match allows ±2 s; anything further apart is another cut of the song.
    static func durationMatches(_ record: LRCLibRecord, _ track: NowPlayingTrack) -> Bool {
        guard let duration = record.duration, track.duration > 0 else { return true }
        return abs(duration - track.duration) <= 3
    }

    /// Every version LRCLIB has that could belong to `track`, best first,
    /// for the "choose different lyrics" screen.
    public func candidates(for track: NowPlayingTrack) async throws -> [LRCLibRecord] {
        let simplified = TitleNormalizer.simplify(track.title)
        var results = try await search(title: simplified, artist: track.primaryArtist)
        if results.isEmpty {
            // Fall back to a free-text search, which tolerates odd artist credits.
            results = try await search(query: "\(simplified) \(track.primaryArtist)")
        }
        return Self.ranked(results, for: track)
    }

    public func get(title: String, artist: String, album: String?, duration: TimeInterval) async throws -> LRCLibRecord? {
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        let (data, status) = try await request(path: "api/get", query: items)
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw LRCLibError.http(status) }
        return try JSONDecoder().decode(LRCLibRecord.self, from: data)
    }

    /// `/api/get/{id}`: a specific record, used when the user picked one by hand.
    public func get(id: Int) async throws -> LRCLibRecord? {
        let (data, status) = try await request(path: "api/get/\(id)", query: [])
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw LRCLibError.http(status) }
        return try JSONDecoder().decode(LRCLibRecord.self, from: data)
    }

    public func search(title: String, artist: String) async throws -> [LRCLibRecord] {
        try await searchRequest([
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ])
    }

    public func search(query: String) async throws -> [LRCLibRecord] {
        try await searchRequest([URLQueryItem(name: "q", value: query)])
    }

    private func searchRequest(_ items: [URLQueryItem]) async throws -> [LRCLibRecord] {
        let (data, status) = try await request(path: "api/search", query: items)
        guard (200..<300).contains(status) else { throw LRCLibError.http(status) }
        return try JSONDecoder().decode([LRCLibRecord].self, from: data)
    }

    /// How well `record` fits `track`, or nil if it is a different song.
    public static func score(_ record: LRCLibRecord, for track: NowPlayingTrack) -> Double? {
        let wantedTitle = TitleNormalizer.comparable(TitleNormalizer.simplify(track.title))
        let wantedArtists = track.artists.map(TitleNormalizer.comparable).filter { !$0.isEmpty }

        let title = TitleNormalizer.comparable(TitleNormalizer.simplify(record.trackName ?? ""))
        guard !title.isEmpty, !wantedTitle.isEmpty,
              title == wantedTitle || title.hasPrefix(wantedTitle) || wantedTitle.hasPrefix(title)
        else { return nil }

        let artist = TitleNormalizer.comparable(record.artistName ?? "")
        guard !artist.isEmpty else { return nil }
        let durationGap = abs((record.duration ?? track.duration) - track.duration)
        // A different cut of the song (live, extended) has different timings.
        guard durationGap <= 5 else { return nil }

        var value = 0.0
        if !wantedArtists.contains(where: { artist.contains($0) || $0.contains(artist) }) {
            // The same artist written in another script ("Kenshi Yonezu" vs "米津玄師") can't be
            // compared. Accept it only with the exact title and nearly the same length, ranked lower.
            guard title == wantedTitle, durationGap <= 2,
                  wantedArtists.contains(where: { Self.differentScripts($0, artist) })
            else { return nil }
            value -= 50
        }

        switch Lyrics(record: record, trackDuration: track.duration) {
        case .synced: value += 100
        case .plain: value += 40
        case .instrumental: value += 20
        // Nothing to show: never let it beat a record that has lyrics.
        case .notFound: return nil
        }
        // The exact title outranks everything else: "Stay" with plain lyrics is right for "Stay",
        // "Stay With Me" with synced lyrics is another song.
        if title == wantedTitle { value += 200 }
        value -= durationGap * 4
        return value
    }

    /// True when one name is plain Latin letters and digits and the other has none of them.
    static func differentScripts(_ a: String, _ b: String) -> Bool {
        func isLatin(_ text: String) -> Bool { text.unicodeScalars.allSatisfy(\.isASCII) }
        func hasLatin(_ text: String) -> Bool { text.unicodeScalars.contains(where: \.isASCII) }
        return (isLatin(a) && !hasLatin(b)) || (isLatin(b) && !hasLatin(a))
    }

    /// Picks the search result that best fits the track: same title and
    /// artist, closest duration, and synced lyrics over plain ones.
    public static func bestMatch(in records: [LRCLibRecord], for track: NowPlayingTrack) -> LRCLibRecord? {
        records
            .compactMap { record in score(record, for: track).map { (record, $0) } }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// All records, matching ones first (best first), then the rest in LRCLIB's order.
    public static func ranked(_ records: [LRCLibRecord], for track: NowPlayingTrack) -> [LRCLibRecord] {
        let scored = records.enumerated().map { (offset: $0.offset, record: $0.element, score: score($0.element, for: track)) }
        return scored.sorted { a, b in
            switch (a.score, b.score) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }
        .map(\.record)
    }

    private func request(path: String, query: [URLQueryItem]) async throws -> (Data, Int) {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let (data, response) = try await http.send(request)
        return (data, response.statusCode)
    }
}

public enum LRCLibError: Error, Equatable {
    case http(Int)
}
