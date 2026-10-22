import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Access and refresh tokens for the Spotify Web API.
public struct SpotifyTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// True if the access token expires within `margin` seconds of `now`.
    public func needsRefresh(now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= margin
    }

    public func hasScope(_ name: String) -> Bool {
        (scope ?? "").split(separator: " ").contains { $0 == name }
    }
}

public enum SpotifyAuthError: Error, Equatable, LocalizedError {
    case missingClientID
    case notSignedIn
    case denied(String)
    case invalidCallback
    case stateMismatch
    /// Spotify refused the code or refresh token (HTTP 400/401).
    case tokenRejected(String?)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .missingClientID: "Add your Spotify Client ID to Config.xcconfig and rebuild."
        case .notSignedIn: "Not signed in to Spotify."
        case .denied(let reason): reason == "access_denied" ? "Spotify sign-in was cancelled." : "Spotify sign-in failed (\(reason))."
        case .invalidCallback, .stateMismatch: "Spotify sent back an unexpected response. Please try again."
        case .tokenRejected(let detail):
            "Spotify rejected the sign-in\(detail.map { " (\($0))" } ?? ""). Check the Client ID, the Redirect URI, and that your account is listed under User Management in the Spotify dashboard."
        case .http(let status): "Spotify sign-in failed (HTTP \(status))."
        }
    }
}

/// The Spotify Accounts service: the Authorization Code flow with PKCE.
/// No client secret is involved, so nothing secret ships in the app.
public struct SpotifyAccounts: Sendable {
    public var clientID: String
    public var redirectURI: String
    public var scopes: [String]
    public var http: HTTPClient
    public var baseURL: URL

    public init(clientID: String, redirectURI: String, scopes: [String], http: HTTPClient,
                baseURL: URL = URL(string: "https://accounts.spotify.com")!) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.http = http
        self.baseURL = baseURL
    }

    public func authorizationURL(verifier: String, state: String) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            // Always ask which account: without it the shared browser session silently reuses
            // whichever Spotify account Safari is logged into (a partner's, say).
            URLQueryItem(name: "show_dialog", value: "true"),
        ]
        return components.url!
    }

    /// Pulls the authorization code out of the redirect Spotify sends back.
    public static func code(fromCallback url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw SpotifyAuthError.denied(error)
        }
        guard value("state") == expectedState else { throw SpotifyAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw SpotifyAuthError.invalidCallback }
        return code
    }

    public func exchange(code: String, verifier: String, now: Date = Date()) async throws -> SpotifyTokens {
        let response = try await requestToken([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier),
        ])
        guard let refresh = response.refresh_token else { throw SpotifyAuthError.invalidCallback }
        return SpotifyTokens(accessToken: response.access_token, refreshToken: refresh,
                             expiresAt: now.addingTimeInterval(TimeInterval(response.expires_in)), scope: response.scope)
    }

    public func refresh(_ tokens: SpotifyTokens, now: Date = Date()) async throws -> SpotifyTokens {
        let response = try await requestToken([
            ("grant_type", "refresh_token"),
            ("refresh_token", tokens.refreshToken),
            ("client_id", clientID),
        ])
        // Spotify may or may not rotate the refresh token.
        return SpotifyTokens(accessToken: response.access_token,
                             refreshToken: response.refresh_token ?? tokens.refreshToken,
                             expiresAt: now.addingTimeInterval(TimeInterval(response.expires_in)),
                             scope: response.scope ?? tokens.scope)
    }

    private func requestToken(_ form: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(form).utf8)
        request.timeoutInterval = 15

        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200..<300:
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        case 400, 401:
            let detail = try? JSONDecoder().decode(TokenError.self, from: data)
            throw SpotifyAuthError.tokenRejected(detail?.error_description ?? detail?.error)
        default:
            throw SpotifyAuthError.http(response.statusCode)
        }
    }
}

private struct TokenResponse: Decodable {
    var access_token: String
    var expires_in: Int
    var refresh_token: String?
    var scope: String?
}

private struct TokenError: Decodable {
    var error: String?
    var error_description: String?
}
