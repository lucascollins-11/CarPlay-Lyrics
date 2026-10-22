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

/// What `GET /v1/me/player/currently-playing` reports.
public struct PlaybackSample: Equatable, Sendable {
    public var track: NowPlayingTrack?
    /// Position in seconds.
    public var position: TimeInterval
    public var isPlaying: Bool

    public init(track: NowPlayingTrack?, position: TimeInterval, isPlaying: Bool) {
        self.track = track
        self.position = position
        self.isPlaying = isPlaying
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
        guard response.currently_playing_type ?? "track" == "track",
              let item = response.item, let id = item.id
        else {
            return PlaybackSample(track: nil, position: position, isPlaying: response.is_playing)
        }
        // Use the largest album image.
        let artwork = item.album?.images?
            .max { ($0.width ?? 0) < ($1.width ?? 0) }
            .flatMap { URL(string: $0.url) }
        let track = NowPlayingTrack(
            id: id,
            title: item.name ?? "",
            artists: item.artists?.map(\.name) ?? [],
            album: item.album?.name ?? "",
            duration: TimeInterval(item.duration_ms ?? 0) / 1000,
            artworkURL: artwork
        )
        return PlaybackSample(track: track, position: position, isPlaying: response.is_playing)
    }
}

// Field names match Spotify's JSON.
private struct CurrentlyPlayingResponse: Decodable {
    var progress_ms: Int?
    var is_playing: Bool
    var currently_playing_type: String?
    var item: Item?

    struct Item: Decodable {
        var id: String?
        var name: String?
        var duration_ms: Int?
        var artists: [Artist]?
        var album: Album?
    }

    struct Artist: Decodable {
        var name: String
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
}
