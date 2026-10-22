import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LyricsCore

final class SpotifyDecodingTests: XCTestCase {
    func testDecodesTrack() throws {
        let body = """
        {"timestamp":1700000000000,"progress_ms":42500,"is_playing":true,"currently_playing_type":"track",
         "item":{"id":"abc","type":"track","name":"Get Lucky (feat. Pharrell Williams)","duration_ms":248413,"is_local":false,
          "artists":[{"name":"Daft Punk"},{"name":"Pharrell Williams"}],
          "album":{"name":"Random Access Memories","images":[{"url":"https://i.scdn.co/small","width":64,"height":64},{"url":"https://i.scdn.co/big","width":640,"height":640}]}}}
        """
        let sample = try PlaybackSample.decode(json(body))
        XCTAssertTrue(sample.isPlaying)
        XCTAssertEqual(sample.position, 42.5, accuracy: 0.0001)
        XCTAssertEqual(sample.track?.id, "abc")
        XCTAssertEqual(sample.track?.title, "Get Lucky (feat. Pharrell Williams)")
        XCTAssertEqual(sample.track?.artists, ["Daft Punk", "Pharrell Williams"])
        XCTAssertEqual(sample.track?.album, "Random Access Memories")
        XCTAssertEqual(sample.track?.duration ?? 0, 248.413, accuracy: 0.0001)
        XCTAssertEqual(sample.track?.artworkURL?.absoluteString, "https://i.scdn.co/big")
    }

    func testPodcastEpisodeAndAdHaveNoTrack() throws {
        XCTAssertNil(try PlaybackSample.decode(json(#"{"progress_ms":1000,"is_playing":true,"currently_playing_type":"episode","item":null}"#)).track)
        XCTAssertNil(try PlaybackSample.decode(json(#"{"progress_ms":1000,"is_playing":true,"currently_playing_type":"ad","item":null}"#)).track)
        XCTAssertNil(try PlaybackSample.decode(json(#"{"progress_ms":1000,"is_playing":true,"currently_playing_type":"unknown"}"#)).track)
    }

    func testPausedTrack() throws {
        let sample = try PlaybackSample.decode(json(#"{"progress_ms":5000,"is_playing":false,"item":{"id":"x","name":"N","duration_ms":1000}}"#))
        XCTAssertFalse(sample.isPlaying)
        XCTAssertEqual(sample.track?.id, "x")
        XCTAssertEqual(sample.track?.artists, [])
        XCTAssertNil(sample.track?.artworkURL)
    }

    func testLocalFileWithoutIDGetsStableKey() throws {
        let body = #"{"progress_ms":0,"is_playing":true,"item":{"id":null,"is_local":true,"name":"Demo Tape","duration_ms":120000,"artists":[{"name":"Me"}],"album":{"name":"","images":[]}}}"#
        let first = try PlaybackSample.decode(json(body)).track
        let second = try PlaybackSample.decode(json(body)).track
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertTrue(first?.id.hasPrefix("local:") ?? false)
    }

    func testMissingFieldsDoNotThrow() throws {
        let sample = try PlaybackSample.decode(json("{}"))
        XCTAssertNil(sample.track)
        XCTAssertFalse(sample.isPlaying)
        XCTAssertEqual(sample.position, 0)
    }

    func testDecodesQueueAndSkipsEpisodes() throws {
        let body = """
        {"currently_playing":{"id":"now","name":"Now","duration_ms":1000},
         "queue":[{"id":"n1","type":"track","name":"Next One","duration_ms":200000,"artists":[{"name":"A"}],"album":{"name":"B"}},
                  {"id":"ep","type":"episode","name":"A Podcast","duration_ms":3600000},
                  {"id":"n2","type":"track","name":"Next Two","duration_ms":180000,"artists":[{"name":"C"}]}]}
        """
        XCTAssertEqual(try SpotifyQueue.decode(json(body)).map(\.id), ["n1", "n2"])
        XCTAssertEqual(try SpotifyQueue.decode(json(#"{"queue":[]}"#)), [])
    }
}

final class PKCETests: XCTestCase {
    func testChallengeMatchesRFC7636Example() {
        // RFC 7636, Appendix B.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testSHA256KnownVectors() {
        func hex(_ string: String) -> String {
            SHA256Digest.hash(Array(string.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex(String(repeating: "a", count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testVerifierIsValidAndRandom() {
        let verifier = PKCE.makeVerifier()
        XCTAssertEqual(verifier.count, 86)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertNotEqual(verifier, PKCE.makeVerifier())
    }

    func testFormEncodingEscapesReservedCharacters() {
        XCTAssertEqual(FormEncoding.encode([("a", "b c"), ("plus", "1+1=2&x"), ("uri", "app://cb")]),
                       "a=b%20c&plus=1%2B1%3D2%26x&uri=app%3A%2F%2Fcb")
    }
}

final class SpotifyAccountsTests: XCTestCase {
    func makeAccounts(_ http: StubHTTP) -> SpotifyAccounts {
        SpotifyAccounts(clientID: "client123", redirectURI: "carplaylyrics://callback",
                        scopes: ["user-read-currently-playing", "user-read-playback-state"], http: http)
    }

    func testAuthorizationURL() {
        let accounts = makeAccounts(StubHTTP { _ in (500, Data(), [:]) })
        let url = accounts.authorizationURL(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s1")
        let request = URLRequest(url: url)
        XCTAssertEqual(url.host, "accounts.spotify.com")
        XCTAssertEqual(url.path, "/authorize")
        XCTAssertEqual(request.query["client_id"], "client123")
        XCTAssertEqual(request.query["response_type"], "code")
        XCTAssertEqual(request.query["redirect_uri"], "carplaylyrics://callback")
        XCTAssertEqual(request.query["code_challenge_method"], "S256")
        XCTAssertEqual(request.query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(request.query["scope"], "user-read-currently-playing user-read-playback-state")
        XCTAssertEqual(request.query["state"], "s1")
    }

    func testCallbackParsing() throws {
        XCTAssertEqual(try SpotifyAccounts.code(fromCallback: URL(string: "carplaylyrics://callback?code=abc&state=s1")!, expectedState: "s1"), "abc")
        XCTAssertThrowsError(try SpotifyAccounts.code(fromCallback: URL(string: "carplaylyrics://callback?code=abc&state=evil")!, expectedState: "s1")) {
            XCTAssertEqual($0 as? SpotifyAuthError, .stateMismatch)
        }
        XCTAssertThrowsError(try SpotifyAccounts.code(fromCallback: URL(string: "carplaylyrics://callback?error=access_denied&state=s1")!, expectedState: "s1")) {
            XCTAssertEqual($0 as? SpotifyAuthError, .denied("access_denied"))
        }
        XCTAssertThrowsError(try SpotifyAccounts.code(fromCallback: URL(string: "carplaylyrics://callback?state=s1")!, expectedState: "s1")) {
            XCTAssertEqual($0 as? SpotifyAuthError, .invalidCallback)
        }
    }

    func testExchangeSendsPKCEFormAndParsesTokens() async throws {
        let http = StubHTTP { _ in
            (200, json(#"{"access_token":"AT","token_type":"Bearer","expires_in":3600,"refresh_token":"RT","scope":"user-read-currently-playing"}"#), [:])
        }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = try await makeAccounts(http).exchange(code: "the/code", verifier: "ver", now: now)
        XCTAssertEqual(tokens, SpotifyTokens(accessToken: "AT", refreshToken: "RT", expiresAt: now.addingTimeInterval(3600),
                                             scope: "user-read-currently-playing"))
        XCTAssertTrue(tokens.hasScope("user-read-currently-playing"))
        XCTAssertFalse(tokens.hasScope("user-modify-playback-state"))

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://accounts.spotify.com/api/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(request.form, ["grant_type": "authorization_code", "code": "the/code", "redirect_uri": "carplaylyrics://callback",
                                      "client_id": "client123", "code_verifier": "ver"])
    }

    func testRefreshKeepsOldRefreshTokenWhenNotRotated() async throws {
        let http = StubHTTP { _ in (200, json(#"{"access_token":"AT2","expires_in":3600}"#), [:]) }
        let old = SpotifyTokens(accessToken: "AT", refreshToken: "RT", expiresAt: .distantPast, scope: "a b")
        let fresh = try await makeAccounts(http).refresh(old, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(fresh.accessToken, "AT2")
        XCTAssertEqual(fresh.refreshToken, "RT")
        XCTAssertEqual(fresh.scope, "a b")
        XCTAssertEqual(http.requests.first?.form, ["grant_type": "refresh_token", "refresh_token": "RT", "client_id": "client123"])
    }

    func testRefreshUsesRotatedRefreshToken() async throws {
        let http = StubHTTP { _ in (200, json(#"{"access_token":"AT2","expires_in":3600,"refresh_token":"RT2"}"#), [:]) }
        let old = SpotifyTokens(accessToken: "AT", refreshToken: "RT", expiresAt: .distantPast)
        let fresh = try await makeAccounts(http).refresh(old)
        XCTAssertEqual(fresh.refreshToken, "RT2")
    }

    func testRejectedTokenSurfacesSpotifysReason() async {
        let http = StubHTTP { _ in (400, json(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#), [:]) }
        do {
            _ = try await makeAccounts(http).refresh(SpotifyTokens(accessToken: "", refreshToken: "RT", expiresAt: .distantPast))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SpotifyAuthError, .tokenRejected("Refresh token revoked"))
            XCTAssertNotNil((error as? SpotifyAuthError)?.errorDescription)
        }
    }

    func testServerErrorIsHTTPError() async {
        let http = StubHTTP { _ in (503, Data(), [:]) }
        do {
            _ = try await makeAccounts(http).exchange(code: "c", verifier: "v")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SpotifyAuthError, .http(503))
        }
    }

    func testNeedsRefresh() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(SpotifyTokens(accessToken: "", refreshToken: "", expiresAt: now.addingTimeInterval(30)).needsRefresh(now: now))
        XCTAssertFalse(SpotifyTokens(accessToken: "", refreshToken: "", expiresAt: now.addingTimeInterval(600)).needsRefresh(now: now))
    }
}

final class SpotifyWebAPITests: XCTestCase {
    /// Records which tokens were asked for.
    final class TokenLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [Bool] = []
        var calls: [Bool] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ force: Bool) -> String {
            lock.lock(); defer { lock.unlock() }
            _calls.append(force)
            return force ? "fresh" : "stale"
        }
    }

    func makeAPI(_ http: StubHTTP, log: TokenLog = TokenLog()) -> SpotifyWebAPI {
        SpotifyWebAPI(http: http) { force in log.record(force) }
    }

    func testCurrentlyPlayingRequest() async throws {
        let http = StubHTTP { _ in (200, json(#"{"progress_ms":1000,"is_playing":true,"item":{"id":"a","name":"A","duration_ms":5000}}"#), [:]) }
        let sample = try await makeAPI(http).currentlyPlaying()
        XCTAssertEqual(sample.track?.id, "a")
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.path, "/v1/me/player/currently-playing")
        XCTAssertEqual(request.query["additional_types"], "track")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stale")
    }

    func testNoContentMeansNothingPlaying() async throws {
        let http = StubHTTP { _ in (204, Data(), [:]) }
        let sample = try await makeAPI(http).currentlyPlaying()
        XCTAssertNil(sample.track)
        XCTAssertFalse(sample.isPlaying)
    }

    /// The position is measured during the final HTTP exchange, not while a token was being refreshed.
    func testTimingCoversOnlyTheFinalExchange() async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: TimeInterval = 0
            func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
            func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
        }
        let clock = Clock()
        let http = StubHTTP { _ in
            clock.advance(0.2)  // the exchange itself
            return (200, json(#"{"progress_ms":1000,"is_playing":true,"item":{"id":"a","name":"A","duration_ms":5000}}"#), [:])
        }
        let api = SpotifyWebAPI(http: http, now: { clock.now() }) { _ in
            clock.advance(1.0)  // a slow token refresh before it
            return "token"
        }
        let sample = try await api.currentlyPlaying()
        XCTAssertEqual(sample.requestStart ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(sample.requestEnd ?? -1, 1.2, accuracy: 0.0001)
    }

    func testRetriesOnceWithFreshTokenAfter401() async throws {
        let http = StubHTTP { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
                ? (204, Data(), [:])
                : (401, Data(), [:])
        }
        let log = TokenLog()
        _ = try await makeAPI(http, log: log).currentlyPlaying()
        XCTAssertEqual(log.calls, [false, true])
        XCTAssertEqual(http.requests.count, 2)
    }

    func testSecond401IsUnauthorized() async {
        let http = StubHTTP { _ in (401, Data(), [:]) }
        await assertThrows(SpotifyAPIError.unauthorized) { _ = try await self.makeAPI(http).currentlyPlaying() }
        XCTAssertEqual(http.requests.count, 2)
    }

    func testRateLimitReadsRetryAfter() async {
        let http = StubHTTP { _ in (429, Data(), ["Retry-After": "12"]) }
        await assertThrows(SpotifyAPIError.rateLimited(retryAfter: 12)) { _ = try await self.makeAPI(http).currentlyPlaying() }
    }

    func testSeekSendsPositionInMilliseconds() async throws {
        let http = StubHTTP { _ in (204, Data(), [:]) }
        try await makeAPI(http).seek(to: 61.2345)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.path, "/v1/me/player/seek")
        XCTAssertEqual(request.query["position_ms"], "61235")
    }

    func testSeekErrors() async {
        await assertThrows(SpotifyAPIError.premiumRequired) {
            try await self.makeAPI(StubHTTP { _ in (403, Data(), [:]) }).seek(to: 1)
        }
        await assertThrows(SpotifyAPIError.noActiveDevice) {
            try await self.makeAPI(StubHTTP { _ in (404, Data(), [:]) }).seek(to: 1)
        }
        await assertThrows(SpotifyAPIError.http(500)) {
            try await self.makeAPI(StubHTTP { _ in (500, Data(), [:]) }).seek(to: 1)
        }
    }

    func testQueue() async throws {
        let http = StubHTTP { _ in (200, json(#"{"queue":[{"id":"q1","name":"Q","duration_ms":1000}]}"#), [:]) }
        let upcoming = try await makeAPI(http).upcomingTracks()
        XCTAssertEqual(upcoming.map(\.id), ["q1"])
        XCTAssertEqual(http.requests.first?.path, "/v1/me/player/queue")
    }

    func testTokenFailurePropagates() async {
        let api = SpotifyWebAPI(http: StubHTTP { _ in (200, Data(), [:]) }) { _ in throw SpotifyAuthError.notSignedIn }
        await assertThrows(SpotifyAuthError.notSignedIn) { _ = try await api.currentlyPlaying() }
    }
}

func assertThrows<E: Error & Equatable>(_ expected: E, file: StaticString = #filePath, line: UInt = #line,
                                        _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? E, expected, file: file, line: line)
    }
}
