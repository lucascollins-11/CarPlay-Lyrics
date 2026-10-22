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

    public init(record: LRCLibRecord?) {
        guard let record else { self = .notFound; return }
        if record.hasSyncedLyrics, let lrc = record.syncedLyrics {
            let timeline = LyricsTimeline(lrc: lrc)
            if !timeline.isEmpty {
                self = .synced(timeline)
                return
            }
        }
        if record.hasPlainLyrics, let plain = record.plainLyrics {
            self = .plain(plain.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        } else if record.instrumental == true {
            self = .instrumental
        } else {
            self = .notFound
        }
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
    public var session: URLSession

    public init(baseURL: URL = URL(string: "https://lrclib.net")!,
                userAgent: String = "CarPlayLyrics/1.0 (https://github.com/carplay-lyrics)",
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.session = session
    }

    /// Finds the best lyrics for a track.
    ///
    /// Tries an exact signature match first (`/api/get`, which LRCLIB matches
    /// within ±2 seconds of the duration), then the simplified title, then a
    /// search ranked by `bestMatch`.
    public func lyrics(for track: NowPlayingTrack) async throws -> LRCLibRecord? {
        let simplified = TitleNormalizer.simplify(track.title)

        if let record = try await get(title: track.title, artist: track.primaryArtist, album: track.album, duration: track.duration),
           record.hasSyncedLyrics {
            return record
        }
        var fallback: LRCLibRecord?
        if simplified != track.title,
           let record = try await get(title: simplified, artist: track.primaryArtist, album: nil, duration: track.duration) {
            if record.hasSyncedLyrics { return record }
            fallback = record
        }
        let results = try await search(title: simplified, artist: track.primaryArtist)
        if let best = Self.bestMatch(in: results, for: track) {
            return best
        }
        return fallback
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
        let (data, status) = try await request(path: "/api/get", query: items)
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw LRCLibError.http(status) }
        return try JSONDecoder().decode(LRCLibRecord.self, from: data)
    }

    public func search(title: String, artist: String) async throws -> [LRCLibRecord] {
        let (data, status) = try await request(path: "/api/search", query: [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ])
        guard (200..<300).contains(status) else { throw LRCLibError.http(status) }
        return try JSONDecoder().decode([LRCLibRecord].self, from: data)
    }

    /// Picks the search result that best fits the track: same title and
    /// artist, closest duration, and synced lyrics over plain ones.
    public static func bestMatch(in records: [LRCLibRecord], for track: NowPlayingTrack) -> LRCLibRecord? {
        let wantedTitle = TitleNormalizer.comparable(TitleNormalizer.simplify(track.title))
        let wantedArtists = track.artists.map(TitleNormalizer.comparable)

        func score(_ record: LRCLibRecord) -> Double? {
            let title = TitleNormalizer.comparable(TitleNormalizer.simplify(record.trackName ?? ""))
            guard !title.isEmpty, title == wantedTitle || title.hasPrefix(wantedTitle) || wantedTitle.hasPrefix(title) else {
                return nil
            }
            let artist = TitleNormalizer.comparable(record.artistName ?? "")
            guard !artist.isEmpty, wantedArtists.contains(where: { !$0.isEmpty && (artist.contains($0) || $0.contains(artist)) }) else {
                return nil
            }
            let durationGap = abs((record.duration ?? 0) - track.duration)
            // A different cut of the song (live, extended) has different timings.
            guard record.duration == nil || durationGap <= 5 else { return nil }

            var value = 0.0
            if record.hasSyncedLyrics { value += 100 }
            else if record.hasPlainLyrics { value += 40 }
            else if record.instrumental == true { value += 20 }
            if title == wantedTitle { value += 10 }
            value -= durationGap * 4
            return value
        }

        return records
            .compactMap { record in score(record).map { (record, $0) } }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func request(path: String, query: [URLQueryItem]) async throws -> (Data, Int) {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum LRCLibError: Error, Equatable {
    case http(Int)
}
