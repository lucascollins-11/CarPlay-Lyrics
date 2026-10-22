import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI

/// Signs in to Spotify with the Authorization Code + PKCE flow and keeps the
/// access token fresh. No client secret is needed, so nothing secret ships in the app.
@MainActor
final class SpotifyAuth: ObservableObject {
    static let shared = SpotifyAuth()

    @Published private(set) var isSignedIn: Bool

    private var tokens: Tokens? {
        didSet { isSignedIn = tokens != nil }
    }
    private var refreshTask: Task<Tokens, Error>?

    private static let keychainAccount = "tokens"

    private init() {
        let stored = Keychain.read(Self.keychainAccount).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
        tokens = stored
        isSignedIn = stored != nil
    }

    // MARK: Sign in / out

    func signIn(using session: WebAuthenticationSession) async throws {
        guard AppConfig.isSpotifyConfigured else { throw SpotifyAuthError.missingClientID }

        let verifier = Self.makeCodeVerifier()
        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.spotifyClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: AppConfig.spotifyRedirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "scope", value: AppConfig.spotifyScopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]

        let callback = try await session.authenticate(
            using: components.url!,
            callbackURLScheme: AppConfig.spotifyCallbackScheme,
            preferredBrowserSession: .shared
        )

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw SpotifyAuthError.denied(error)
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else { throw SpotifyAuthError.invalidCallback }

        let response = try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": AppConfig.spotifyRedirectURI,
            "client_id": AppConfig.spotifyClientID,
            "code_verifier": verifier,
        ])
        store(Tokens(response: response, previousRefreshToken: nil))
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        Keychain.delete(Self.keychainAccount)
    }

    // MARK: Tokens

    /// A valid access token, refreshed first if it is about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens else { throw SpotifyAuthError.notSignedIn }
        if !forceRefresh, tokens.expiresAt.timeIntervalSinceNow > 60 {
            return tokens.accessToken
        }
        return try await refresh(tokens).accessToken
    }

    private func refresh(_ current: Tokens) async throws -> Tokens {
        // Share one refresh between callers (the iPhone and CarPlay screens poll at the same time).
        if let refreshTask { return try await refreshTask.value }
        let task = Task { () throws -> Tokens in
            let response = try await self.requestToken([
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": AppConfig.spotifyClientID,
            ])
            return Tokens(response: response, previousRefreshToken: current.refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            store(fresh)
            return fresh
        } catch SpotifyAuthError.tokenRejected {
            // The refresh token was revoked; the user has to sign in again.
            signOut()
            throw SpotifyAuthError.notSignedIn
        }
    }

    private func store(_ tokens: Tokens) {
        self.tokens = tokens
        if let data = try? JSONEncoder().encode(tokens) {
            Keychain.write(data, for: Self.keychainAccount)
        }
    }

    private func requestToken(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 {
            throw SpotifyAuthError.tokenRejected
        }
        guard (200..<300).contains(status) else { throw SpotifyAuthError.http(status) }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: Helpers

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        .joined(separator: "&")
    }
}

private struct TokenResponse: Decodable {
    var access_token: String
    var expires_in: Int
    var refresh_token: String?
}

private struct Tokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    init(response: TokenResponse, previousRefreshToken: String?) {
        accessToken = response.access_token
        // Spotify may or may not rotate the refresh token.
        refreshToken = response.refresh_token ?? previousRefreshToken ?? ""
        expiresAt = Date().addingTimeInterval(TimeInterval(response.expires_in))
    }
}

enum SpotifyAuthError: LocalizedError {
    case missingClientID
    case notSignedIn
    case denied(String)
    case invalidCallback
    case tokenRejected
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "Add your Spotify Client ID to Config.xcconfig and rebuild."
        case .notSignedIn: "Sign in to Spotify on your iPhone."
        case .denied(let reason): "Spotify sign-in was cancelled (\(reason))."
        case .invalidCallback: "Spotify sent back an unexpected response. Try again."
        case .tokenRejected: "Spotify rejected the sign-in. Check the Client ID and Redirect URI in the Spotify dashboard."
        case .http(let status): "Spotify sign-in failed (HTTP \(status))."
        }
    }
}
