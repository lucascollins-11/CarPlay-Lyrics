import Foundation
import LyricsCore

/// The one Spotify Web API call the app needs.
struct SpotifyAPI {
    enum Failure: Error {
        case unauthorized
        case rateLimited(retryAfter: TimeInterval)
        case http(Int)
    }

    /// `GET /v1/me/player/currently-playing`. Returns `.nothing` when Spotify
    /// is idle on every device.
    func currentlyPlaying(accessToken: String) async throws -> PlaybackSample {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing?additional_types=track")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200 where !data.isEmpty:
            return try PlaybackSample.decode(data)
        case 200, 204:
            return .nothing
        case 401:
            throw Failure.unauthorized
        case 429:
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) } ?? 5
            throw Failure.rateLimited(retryAfter: retryAfter)
        case let status:
            throw Failure.http(status)
        }
    }
}
