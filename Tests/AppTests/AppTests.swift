import CarPlay
import LyricsCore
import XCTest
@testable import CarPlayLyrics

@MainActor
final class ScopeTests: XCTestCase {
    /// Data minimisation: the default sign-in may only read what's playing.
    func testDefaultScopesAreReadOnly() {
        XCTAssertEqual(AppConfig.spotifyScopes, ["user-read-currently-playing", "user-read-playback-state"])
        XCTAssertEqual(SpotifyAuth.scopes(includingSeek: false), AppConfig.spotifyScopes)
        XCTAssertEqual(SpotifyAuth.scopes(includingSeek: true), AppConfig.spotifyScopes + ["user-modify-playback-state"])
    }

    func testLRCLibUserAgentHasNoPersonalData() {
        let agent = AppConfig.lrclibUserAgent
        XCTAssertTrue(agent.hasPrefix("CarPlayLyrics/"))
        XCTAssertFalse(agent.contains(UIDevice.current.name))
        XCTAssertFalse(agent.lowercased().contains("iphone"))
    }

    func testRedirectURIMatchesCallbackScheme() {
        XCTAssertTrue(AppConfig.spotifyRedirectURI.hasPrefix(AppConfig.spotifyCallbackScheme + "://"))
    }

    func testBundledLegalDocuments() {
        XCTAssertTrue(LegalDocumentView.load(.privacy).contains("Privacy Policy"))
        XCTAssertTrue(LegalDocumentView.load(.terms).contains("Terms of Use"))
        XCTAssertNotNil(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    }
}

@MainActor
final class SpotifyAuthTests: XCTestCase {
    func tokens(_ access: String, expires: Date) -> SpotifyTokens {
        SpotifyTokens(accessToken: access, refreshToken: "refresh", expiresAt: expires, scope: "user-read-currently-playing")
    }

    func testRestoresTokensFromTheStore() throws {
        let store = InMemoryTokenStore(data: try JSONEncoder().encode(tokens("A", expires: .distantFuture)))
        let auth = SpotifyAuth(store: store, http: StubHTTP { _ in (500, Data()) })
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.canSeek)
    }

    func testFreshTokenIsReturnedWithoutNetwork() async throws {
        let http = StubHTTP { _ in (500, Data()) }
        let auth = SpotifyAuth(store: InMemoryTokenStore(), http: http)
        auth.installForTesting(tokens("A", expires: .distantFuture))
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "A")
        XCTAssertEqual(http.count, 0)
    }

    func testExpiringTokenIsRefreshedAndSaved() async throws {
        let http = StubHTTP { _ in (200, Data(#"{"access_token":"B","expires_in":3600}"#.utf8)) }
        let store = InMemoryTokenStore()
        let auth = SpotifyAuth(store: store, http: http)
        auth.installForTesting(tokens("A", expires: Date().addingTimeInterval(10)))
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "B")
        let saved = try JSONDecoder().decode(SpotifyTokens.self, from: XCTUnwrap(store.data))
        XCTAssertEqual(saved.accessToken, "B")
        XCTAssertEqual(saved.refreshToken, "refresh", "kept when Spotify doesn't rotate it")
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let http = StubHTTP { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            return (200, Data(#"{"access_token":"B","expires_in":3600}"#.utf8))
        }
        let auth = SpotifyAuth(store: InMemoryTokenStore(), http: http)
        auth.installForTesting(tokens("A", expires: .distantPast))
        async let one = auth.accessToken()
        async let two = auth.accessToken()
        async let three = auth.accessToken(forceRefresh: true)
        let results = try await [one, two, three]
        XCTAssertEqual(results, ["B", "B", "B"])
        XCTAssertEqual(http.count, 1)
    }

    func testSignOutDuringRefreshStaysSignedOut() async {
        let http = StubHTTP { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return (200, Data(#"{"access_token":"B","expires_in":3600}"#.utf8))
        }
        let store = InMemoryTokenStore()
        let auth = SpotifyAuth(store: store, http: http)
        auth.installForTesting(tokens("A", expires: .distantPast))
        let pending = Task { try await auth.accessToken() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        auth.signOut()
        let result = await pending.result
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? SpotifyAuthError, .notSignedIn) }
        XCTAssertFalse(auth.isSignedIn, "the finished refresh must not sign the user back in")
        XCTAssertNil(store.data)
    }

    func testRevokedRefreshTokenSignsOutEveryCaller() async {
        let http = StubHTTP { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let auth = SpotifyAuth(store: InMemoryTokenStore(), http: http)
        auth.installForTesting(tokens("A", expires: .distantPast))
        let one = Task { try await auth.accessToken() }
        let two = Task { try await auth.accessToken() }
        for result in [await one.result, await two.result] {
            XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? SpotifyAuthError, .notSignedIn) }
        }
        XCTAssertFalse(auth.isSignedIn)
    }

    func testNetworkErrorDuringRefreshKeepsTheSession() async {
        let auth = SpotifyAuth(store: InMemoryTokenStore(), http: StubHTTP { _ in throw URLError(.notConnectedToInternet) })
        auth.installForTesting(tokens("A", expires: .distantPast))
        do {
            _ = try await auth.accessToken()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertTrue(auth.isSignedIn, "a dead zone in the car must not sign you out")
    }

    func testNotSignedIn() async {
        let auth = SpotifyAuth(store: InMemoryTokenStore(), http: StubHTTP { _ in (500, Data()) })
        do {
            _ = try await auth.accessToken()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SpotifyAuthError, .notSignedIn)
        }
    }
}

@MainActor
final class AppSettingsTests: XCTestCase {
    func testPersistsAndDeletesEverything() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.globalOffset = 0.3
        settings.trackOffsets = ["a": 0.25]
        settings.demoMode = true
        settings.keepScreenAwake = true
        settings.driveModeEnabled = true
        settings.allowSeeking = true
        settings.lyricsTextSize = .large

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.globalOffset, 0.3)
        XCTAssertEqual(reloaded.trackOffsets, ["a": 0.25])
        XCTAssertTrue(reloaded.demoMode)
        XCTAssertEqual(reloaded.lyricsTextSize, .large)

        reloaded.deleteAll()
        for key in AppSettings.Key.allCases {
            XCTAssertNil(defaults.object(forKey: key.rawValue), key.rawValue)
        }
        XCTAssertEqual(reloaded.globalOffset, 0)
        XCTAssertFalse(reloaded.demoMode)
    }

    func testMigratesTheFirstVersionsOffset() {
        let defaults = freshDefaults()
        defaults.set(0.75, forKey: "timingOffset")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.globalOffset, 0.75)
        XCTAssertNil(defaults.object(forKey: "timingOffset"))
    }
}

@MainActor
final class CarPlayTemplateTests: XCTestCase {
    func makeTemplate() -> (CarPlayLyricsTemplate, NowPlayingModel) {
        let settings = AppSettings(defaults: freshDefaults())
        let auth = SpotifyAuth(store: InMemoryTokenStore(), http: StubHTTP { _ in (500, Data()) })
        let model = NowPlayingModel(settings: settings, auth: auth, dependencies: .init(
            spotify: FakePlayback(), lyrics: FakeLyrics(), store: nil, demo: DemoPlayback(),
            demoLyrics: DemoLyricsProvider(), now: { 0 }))
        return (CarPlayLyricsTemplate(model: model), model)
    }

    func snapshot(line: Int?) -> NowPlayingSnapshot {
        NowPlayingSnapshot(isSignedIn: true, track: makeTrack("a"), isPlaying: true,
                           lyrics: .loaded(.synced(makeTimeline())), currentLine: line)
    }

    func testSignedOutShowsMessageWithoutRows() {
        let (template, _) = makeTemplate()
        template.render(NowPlayingSnapshot(isSignedIn: false))
        XCTAssertTrue(template.visibleRows.isEmpty)
        XCTAssertEqual(template.template.emptyViewTitleVariants, ["Spotify isn't connected"])
        XCTAssertFalse(template.template.emptyViewSubtitleVariants.joined().lowercased().contains("iphone"))
    }

    func testRowsFollowTheSongAndUpdateInPlace() {
        let (template, _) = makeTemplate()
        template.render(snapshot(line: 3))
        let rows = template.visibleRows
        XCTAssertLessThanOrEqual(rows.count, CarPlayLyricsTemplate.maxRows)
        XCTAssertEqual(rows.first?.text, "line 2")
        XCTAssertEqual(rows.filter(\.isCurrent).map(\.text), ["line 3"])
        let firstItem = template.template.sections.first?.items.first as? CPListItem

        template.render(snapshot(line: 4))
        XCTAssertEqual(template.visibleRows.filter(\.isCurrent).map(\.text), ["line 4"])
        XCTAssertTrue(template.template.sections.first?.items.first as? CPListItem === firstItem,
                      "same rows are reused, not rebuilt")
    }

    func testRowsAreNotTappable() {
        let (template, _) = makeTemplate()
        template.render(snapshot(line: 1))
        for item in template.template.sections.first?.items ?? [] {
            XCTAssertNil((item as? CPListItem)?.handler, "lyric rows must not invite interaction while driving")
        }
    }

    func testTimingButtonsExist() {
        let (template, _) = makeTemplate()
        XCTAssertEqual(template.template.trailingNavigationBarButtons.compactMap(\.title), ["Earlier", "Later"])
    }
}

@MainActor
final class BackgroundKeepAliveTests: XCTestCase {
    func testSilentWAVIsWellFormed() {
        let data = BackgroundKeepAlive.silentWAV(sampleRate: 8000)
        XCTAssertEqual(data.count, 44 + 16000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertTrue(data.dropFirst(44).allSatisfy { $0 == 0 }, "silence")
    }
}

final class DriveModeIdlePolicyTests: XCTestCase {
    func at(_ minutes: Double) -> TimeInterval { 1000 + minutes * 60 }

    func testNeverStopsWhileConnectedToCarPlay() {
        var policy = DriveModeIdlePolicy()
        for minute in stride(from: 0.0, through: 120, by: 0.5) {
            XCTAssertFalse(policy.shouldStop(isPlaying: false, inCar: true, now: at(minute)), "a fuel stop with the car on")
        }
    }

    func testStopsAfterIdleWhenNotInTheCar() {
        var policy = DriveModeIdlePolicy()
        XCTAssertFalse(policy.shouldStop(isPlaying: true, inCar: false, now: at(0)))
        XCTAssertFalse(policy.shouldStop(isPlaying: false, inCar: false, now: at(1)))
        XCTAssertFalse(policy.shouldStop(isPlaying: false, inCar: false, now: at(15)))
        XCTAssertTrue(policy.shouldStop(isPlaying: false, inCar: false, now: at(16)))
    }

    func testPlayingResetsTheIdleTimer() {
        var policy = DriveModeIdlePolicy()
        XCTAssertFalse(policy.shouldStop(isPlaying: false, inCar: false, now: at(0)))
        XCTAssertFalse(policy.shouldStop(isPlaying: true, inCar: false, now: at(14)))
        XCTAssertFalse(policy.shouldStop(isPlaying: false, inCar: false, now: at(20)))
        XCTAssertFalse(policy.shouldStop(isPlaying: false, inCar: false, now: at(34)))
        XCTAssertTrue(policy.shouldStop(isPlaying: false, inCar: false, now: at(35)))
    }

    func testStopsAWhileAfterLeavingTheCarEvenWithMusic() {
        var policy = DriveModeIdlePolicy()
        XCTAssertFalse(policy.shouldStop(isPlaying: true, inCar: true, now: at(0)))
        XCTAssertFalse(policy.shouldStop(isPlaying: true, inCar: false, now: at(30)), "just got out")
        XCTAssertFalse(policy.shouldStop(isPlaying: true, inCar: false, now: at(45)))
        XCTAssertTrue(policy.shouldStop(isPlaying: true, inCar: false, now: at(50)))
    }

    func testGettingBackInTheCarCancelsTheCountdown() {
        var policy = DriveModeIdlePolicy()
        _ = policy.shouldStop(isPlaying: false, inCar: true, now: at(0))
        XCTAssertFalse(policy.shouldStop(isPlaying: false, inCar: false, now: at(1)))
        XCTAssertFalse(policy.shouldStop(isPlaying: false, inCar: true, now: at(10)), "back from the coffee shop")
        XCTAssertFalse(policy.shouldStop(isPlaying: true, inCar: true, now: at(40)))
    }
}
