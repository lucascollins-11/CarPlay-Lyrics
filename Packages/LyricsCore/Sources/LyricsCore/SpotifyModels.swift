import Foundation

/// The track that is playing, reduced to what the app needs.
public struct NowPlayingTrack: Equatable, Hashable, Sendable, Codable {
    public var id: String
    public var title: String
    public var artists: [String]
    public var album: String
    /// Track length in seconds.
    public var duration: TimeInterval
    public var artworkURL: URL?

    public init(id: String, title: String, artists: [String], album: String, duration: TimeInterval, artworkURL: URL? = nil) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
    }

    public var primaryArtist: String { artists.first ?? "" }
    public var artistLine: String { artists.joined(separator: ", ") }
}

/// What Spotify is playing, from `currently_playing_type`. Only `.track` has lyrics.
public enum PlayingKind: String, Equatable, Sendable {
    /// Nothing is playing (204, or no item).
    case nothing
    case track
    case episode
    case ad
    /// Something Spotify doesn't describe, or a track the app can't identify.
    case unknown
}

/// What `GET /v1/me/player/currently-playing` reports.
public struct PlaybackSample: Equatable, Sendable {
    public var track: NowPlayingTrack?
    /// Why `track` is nil when something is playing: a podcast episode, an ad, or something else.
    public var kind: PlayingKind
    /// Position in seconds.
    public var position: TimeInterval
    public var isPlaying: Bool
    /// When the HTTP exchange that produced this sample started and ended, on
    /// the source's monotonic clock. Spotify measured `position` somewhere in
    /// between. Nil when the source can't tell (the demo song).
    public var requestStart: TimeInterval?
    public var requestEnd: TimeInterval?

    public init(track: NowPlayingTrack?, position: TimeInterval, isPlaying: Bool, kind: PlayingKind? = nil,
                requestStart: TimeInterval? = nil, requestEnd: TimeInterval? = nil) {
        self.track = track
        self.kind = kind ?? (track == nil ? .nothing : .track)
        self.position = position
        self.isPlaying = isPlaying
        self.requestStart = requestStart
        self.requestEnd = requestEnd
    }

    /// Nothing is playing (Spotify answers 204 No Content).
    public static let nothing = PlaybackSample(track: nil, position: 0, isPlaying: false)

    /// Decodes the JSON body of `GET /v1/me/player/currently-playing`.
    ///
    /// Podcast episodes and ads come back without a usable track, so they
    /// decode with `track == nil`.
    public static func decode(_ data: Data) throws -> PlaybackSample {
        let response = try JSONDecoder().decode(CurrentlyPlayingResponse.self, from: data)
        let position = TimeInterval(response.progress_ms ?? 0) / 1000
        let type = response.currently_playing_type ?? "track"
        let track = type == "track" ? response.item?.track : nil
        let kind: PlayingKind
        switch type {
        case "track": kind = track != nil ? .track : (response.item == nil ? .nothing : .unknown)
        case "episode": kind = .episode
        case "ad": kind = .ad
        default: kind = .unknown
        }
        return PlaybackSample(track: track, position: position, isPlaying: response.is_playing ?? false, kind: kind)
    }
}

/// `GET /v1/me/player/queue`: the tracks coming up next, used to prefetch lyrics.
public enum SpotifyQueue {
    public static func decode(_ data: Data) throws -> [NowPlayingTrack] {
        let response = try JSONDecoder().decode(QueueResponse.self, from: data)
        return (response.queue ?? []).compactMap(\.track)
    }
}

// Field names match Spotify's JSON.
struct SpotifyItem: Decodable {
    var id: String?
    var type: String?
    var name: String?
    var duration_ms: Int?
    var is_local: Bool?
    var artists: [Artist]?
    var album: Album?

    struct Artist: Decodable {
        var name: String?
    }

    struct Album: Decodable {
        var name: String?
        var images: [Image]?
    }

    struct Image: Decodable {
        var url: String
        var width: Int?
        var height: Int?
    }

    /// Nil for episodes, and for items Spotify gives no ID (some local files).
    var track: NowPlayingTrack? {
        guard type == nil || type == "track", let name, !name.isEmpty else { return nil }
        let artistNames = artists?.compactMap(\.name) ?? []
        // Local files have no Spotify ID; key them by title and artist so lyrics still cache.
        let key = id ?? (is_local == true ? "local:\(artistNames.joined(separator: ","))-\(name)" : nil)
        guard let key else { return nil }
        let artwork = album?.images?
            .max { ($0.width ?? 0) < ($1.width ?? 0) }
            .flatMap { URL(string: $0.url) }
        return NowPlayingTrack(
            id: key,
            title: name,
            artists: artistNames,
            album: album?.name ?? "",
            duration: TimeInterval(duration_ms ?? 0) / 1000,
            artworkURL: artwork
        )
    }
}

private struct CurrentlyPlayingResponse: Decodable {
    var progress_ms: Int?
    var is_playing: Bool?
    var currently_playing_type: String?
    var item: SpotifyItem?
}

private struct QueueResponse: Decodable {
    var queue: [SpotifyItem]?
}
