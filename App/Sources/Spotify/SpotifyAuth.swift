import AuthenticationServices
import Foundation
import LyricsCore
import SwiftUI

/// Signs in to Spotify (Authorization Code + PKCE) and hands out fresh access tokens.
@MainActor
final class SpotifyAuth: ObservableObject {
    @Published private(set) var isSignedIn: Bool
    /// The scopes Spotify actually granted.
    @Published private(set) var grantedScope: String?

    private let tokenStore: TokenStore
    private let http: HTTPClient
    private let now: () -> Date
    private var tokens: SpotifyTokens? {
        didSet {
            isSignedIn = tokens != nil
            grantedScope = tokens?.scope
        }
    }
    private var refreshTask: Task<SpotifyTokens, Error>?
    /// Bumped on every sign-in and sign-out, so a refresh that finishes afterwards is thrown away.
    private var generation = 0

    init(store: TokenStore = KeychainTokenStore(), http: HTTPClient = URLSession.shared, now: @escaping () -> Date = Date.init) {
        self.tokenStore = store
        self.http = http
        self.now = now
        let stored = store.load().flatMap { try? JSONDecoder().decode(SpotifyTokens.self, from: $0) }
        tokens = stored
        isSignedIn = stored != nil
        grantedScope = stored?.scope
    }

    var canSeek: Bool {
        tokens?.hasScope(AppConfig.spotifySeekScope) ?? false
    }

    private func accounts(scopes: [String]) -> SpotifyAccounts {
        SpotifyAccounts(clientID: AppConfig.spotifyClientID, redirectURI: AppConfig.spotifyRedirectURI, scopes: scopes, http: http)
    }

    static func scopes(includingSeek: Bool) -> [String] {
        includingSeek ? AppConfig.spotifyScopes + [AppConfig.spotifySeekScope] : AppConfig.spotifyScopes
    }

    // MARK: Sign in / out

    func signIn(using session: WebAuthenticationSession, includeSeek: Bool) async throws {
        guard AppConfig.isSpotifyConfigured else { throw SpotifyAuthError.missingClientID }
        let accounts = accounts(scopes: Self.scopes(includingSeek: includeSeek))
        let verifier = PKCE.makeVerifier()
        let state = UUID().uuidString

        let callback = try await session.authenticate(
            using: accounts.authorizationURL(verifier: verifier, state: state),
            callbackURLScheme: AppConfig.spotifyCallbackScheme,
            preferredBrowserSession: .shared
        )
        let code = try SpotifyAccounts.code(fromCallback: callback, expectedState: state)
        let fresh = try await accounts.exchange(code: code, verifier: verifier, now: now())
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        save(fresh)
    }

    func signOut() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        tokenStore.delete()
    }

    // MARK: Tokens

    /// A valid access token, refreshed first if it is about to expire.
    /// Throws `SpotifyAuthError.notSignedIn` whenever the user has to sign in again.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw SpotifyAuthError.notSignedIn }
        if !forceRefresh, !current.needsRefresh(now: now()) {
            return current.accessToken
        }
        return try await refreshed(from: current).accessToken
    }

    private func refreshed(from current: SpotifyTokens) async throws -> SpotifyTokens {
        // One refresh at a time; the iPhone screen, CarPlay and prefetching can all ask at once.
        let task: Task<SpotifyTokens, Error>
        if let running = refreshTask {
            task = running
        } else {
            let accounts = accounts(scopes: [])
            let now = now()
            task = Task { try await accounts.refresh(current, now: now) }
            refreshTask = task
        }
        let startedGeneration = generation

        do {
            let fresh = try await task.value
            if refreshTask == task { refreshTask = nil }
            // Signed out (or in again) while this was running: don't resurrect the old session.
            guard generation == startedGeneration, tokens != nil else { throw SpotifyAuthError.notSignedIn }
            if tokens != fresh { save(fresh) }
            return fresh
        } catch let error as SpotifyAuthError {
            if refreshTask == task { refreshTask = nil }
            if case .tokenRejected = error {
                // The refresh token was revoked (for example from spotify.com/account/apps).
                if generation == startedGeneration { signOut() }
                throw SpotifyAuthError.notSignedIn
            }
            throw error
        } catch {
            if refreshTask == task { refreshTask = nil }
            if generation != startedGeneration { throw SpotifyAuthError.notSignedIn }
            throw error
        }
    }

    private func save(_ tokens: SpotifyTokens) {
        self.tokens = tokens
        if let data = try? JSONEncoder().encode(tokens) {
            tokenStore.save(data)
        }
    }

    /// Test hook: install tokens directly.
    func installForTesting(_ tokens: SpotifyTokens?) {
        generation += 1
        self.tokens = tokens
    }
}
