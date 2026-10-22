import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the app learns what is playing. Spotify in the real app, a built-in song in demo mode.
public protocol PlaybackSource: Sendable {
    func currentlyPlaying() async throws -> PlaybackSample
    /// Tracks that will play next, used to prefetch lyrics. May be empty.
    func upcomingTracks() async throws -> [NowPlayingTrack]
    /// Jumps playback to `position` seconds into the current track.
    func seek(to position: TimeInterval) async throws
}

public enum SpotifyAPIError: Error, Equatable, LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval)
    /// Spotify refused this account (HTTP 403). In Development mode that means
    /// the account isn't listed under User Management in the Spotify dashboard.
    case forbidden
    /// Controlling playback needs Spotify Premium (HTTP 403 from a player command).
    case premiumRequired
    case noActiveDevice
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Spotify signed you out. Please sign in again."
        case .rateLimited: "Spotify asked us to slow down. Retrying shortly."
        case .forbidden: "Spotify won't share playback with this app for your account. Add your account under User Management in the Spotify developer dashboard."
        case .premiumRequired: "Jumping to a line needs Spotify Premium."
        case .noActiveDevice: "Spotify isn't playing on any device right now."
        case .http(let status): "Spotify returned an error (HTTP \(status))."
        }
    }
}

/// The few Spotify Web API endpoints the app uses.
public struct SpotifyWebAPI: PlaybackSource {
    /// Returns a valid access token; `forceRefresh` asks for a new one after a 401.
    public typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    public var http: HTTPClient
    public var token: TokenProvider
    public var baseURL: URL
    /// The clock used to time requests; must match the clock the app follows the song with.
    public var now: @Sendable () -> TimeInterval

    public init(http: HTTPClient, baseURL: URL = URL(string: "https://api.spotify.com/v1")!,
                now: @escaping @Sendable () -> TimeInterval = { MonotonicClock.now() }, token: @escaping TokenProvider) {
        self.http = http
        self.token = token
        self.baseURL = baseURL
        self.now = now
    }

    public func currentlyPlaying() async throws -> PlaybackSample {
        let response = try await send("GET", "me/player/currently-playing", query: [URLQueryItem(name: "additional_types", value: "track")])
        var sample = response.status == 204 || response.data.isEmpty ? PlaybackSample.nothing : try PlaybackSample.decode(response.data)
        // Only the final exchange counts: a token refresh or a retry before it says nothing about when Spotify measured.
        sample.requestStart = response.start
        sample.requestEnd = response.end
        return sample
    }

    public func upcomingTracks() async throws -> [NowPlayingTrack] {
        let response = try await send("GET", "me/player/queue")
        if response.status == 204 || response.data.isEmpty { return [] }
        return try SpotifyQueue.decode(response.data)
    }

    public func seek(to position: TimeInterval) async throws {
        let ms = max(0, Int((position * 1000).rounded()))
        do {
            _ = try await send("PUT", "me/player/seek", query: [URLQueryItem(name: "position_ms", value: String(ms))])
        } catch SpotifyAPIError.forbidden {
            throw SpotifyAPIError.premiumRequired
        }
    }

    /// Sends an authorized request, refreshing the token once on 401.
    private struct Response {
        var data: Data
        var status: Int
        var start: TimeInterval
        var end: TimeInterval
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Response {
        var attempt = 0
        while true {
            let accessToken = try await token(attempt > 0)
            var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if !query.isEmpty { components.queryItems = query }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 8
            if method == "PUT" {
                request.httpBody = Data()
                request.setValue("0", forHTTPHeaderField: "Content-Length")
            }

            let start = now()
            let (data, response) = try await http.send(request)
            let end = now()
            switch response.statusCode {
            case 200..<300:
                return Response(data: data, status: response.statusCode, start: start, end: end)
            case 401 where attempt == 0:
                attempt += 1
                continue
            case 401:
                throw SpotifyAPIError.unauthorized
            case 403:
                throw SpotifyAPIError.forbidden
            case 404:
                throw SpotifyAPIError.noActiveDevice
            case 429:
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) } ?? 5
                throw SpotifyAPIError.rateLimited(retryAfter: retryAfter)
            default:
                throw SpotifyAPIError.http(response.statusCode)
            }
        }
    }
}
