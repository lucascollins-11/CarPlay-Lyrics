import LyricsCore
import XCTest
@testable import CarPlayLyrics

@MainActor
final class NowPlayingModelTests: XCTestCase {
    var clock: ManualClock!
    var spotify: FakePlayback!
    var lyrics: FakeLyrics!
    var settings: AppSettings!
    var auth: SpotifyAuth!
    var model: NowPlayingModel!
    var demo: DemoPlayback!

    override func setUp() async throws {
        clock = ManualClock()
        spotify = FakePlayback()
        lyrics = FakeLyrics()
        settings = AppSettings(defaults: freshDefaults())
        auth = SpotifyAuth(store: InMemoryTokenStore(), http: StubHTTP { _ in (500, Data()) })
        auth.installForTesting(SpotifyTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture,
                                             scope: AppConfig.spotifyScopes.joined(separator: " ")))
        let clock = self.clock!
        demo = DemoPlayback(now: { clock.now })
        model = NowPlayingModel(settings: settings, auth: auth, dependencies: .init(
            spotify: spotify, lyrics: lyrics, store: nil, demo: demo, demoLyrics: DemoLyricsProvider(),
            now: { clock.now }))
    }

    func testTrackLoadsLyricsAndFollowsLines() async {
        let track = makeTrack("a")
        lyrics.set(.synced(makeTimeline()), for: "a")
        spotify.play(track, at: 0)

        await model.pollOnce()
        XCTAssertEqual(model.snapshot.track, track)
        await waitUntil { if case .loaded = self.model.snapshot.lyrics { return true }; return false }
        XCTAssertNil(model.snapshot.currentLine)

        clock.advance(2.1)
        model.tick()
        XCTAssertEqual(model.snapshot.currentLine, 0)
        clock.advance(5)
        model.tick()
        XCTAssertEqual(model.snapshot.currentLine, 1)
    }

    func testPrefetchesUpcomingLyrics() async {
        spotify.play(makeTrack("a"), at: 0)
        spotify.upcoming = [makeTrack("b"), makeTrack("c"), makeTrack("d")]
        await model.pollOnce()
        await waitUntil(timeout: 4) { self.lyrics.requested.contains("c") }
        XCTAssertFalse(lyrics.requested.contains("d"), "only the next two are prefetched")
    }

    func testLyricsFailureIsShownAndRetried() async {
        lyrics.fail = true
        spotify.play(makeTrack("a"), at: 0)
        await model.pollOnce()
        await waitUntil { if case .failed = self.model.snapshot.lyrics { return true }; return false }

        lyrics.fail = false
        lyrics.set(.instrumental, for: "a")
        clock.advance(25)
        spotify.play(makeTrack("a"), at: 25)
        await model.pollOnce()
        await waitUntil { self.model.snapshot.lyrics == .loaded(.instrumental) }
    }

    func testForbiddenShowsUserManagementHint() async {
        spotify.next = .failure(SpotifyAPIError.forbidden)
        let delay = await model.pollOnce()
        XCTAssertEqual(delay, 30)
        XCTAssertEqual(model.snapshot.problem, SpotifyAPIError.forbidden.errorDescription)
        XCTAssertTrue(model.snapshot.problem?.contains("User Management") ?? false)
    }

    func testPersistentUnauthorizedSignsOut() async {
        spotify.play(makeTrack("a"), at: 0)
        await model.pollOnce()
        spotify.next = .failure(SpotifyAPIError.unauthorized)
        for _ in 1..<NowPlayingEngine.maxUnauthorized { await model.pollOnce() }
        XCTAssertTrue(auth.isSignedIn, "one or two 401s can be a blip")
        await model.pollOnce()
        XCTAssertFalse(auth.isSignedIn, "the sign-in screen comes back instead of polling forever")
        await waitUntil { !self.model.snapshot.isSignedIn }
    }

    func testCancellationIsNotAProblem() async {
        spotify.next = .failure(URLError(.cancelled))
        await model.pollOnce()
        XCTAssertNil(model.snapshot.problem)
    }

    func testRateLimitWaitsRetryAfter() async {
        spotify.next = .failure(SpotifyAPIError.rateLimited(retryAfter: 17))
        let delay = await model.pollOnce()
        XCTAssertEqual(delay, 17)
    }

    func testPerSongOffsetIsSavedToSettings() async {
        spotify.play(makeTrack("a"), at: 0)
        await model.pollOnce()
        model.adjustTrackOffset(by: 0.25)
        model.adjustTrackOffset(by: 0.25)
        XCTAssertEqual(model.snapshot.trackOffset, 0.5)
        XCTAssertEqual(settings.trackOffsets, ["a": 0.5])
        model.resetTrackOffset()
        XCTAssertEqual(settings.trackOffsets, [:])
    }

    func testGlobalOffsetFromSettingsMovesTheLine() async {
        lyrics.set(.synced(makeTimeline()), for: "a")
        spotify.play(makeTrack("a"), at: 6.7)
        await model.pollOnce()
        await waitUntil { self.model.snapshot.currentLine == 0 }
        settings.globalOffset = 0.5
        XCTAssertEqual(model.snapshot.currentLine, 1)
    }

    func testSeekingNeedsTheSettingAndPermission() async {
        lyrics.set(.synced(makeTimeline()), for: "a")
        spotify.play(makeTrack("a"), at: 0)
        await model.pollOnce()
        await waitUntil { self.model.snapshot.timeline != nil }

        XCTAssertFalse(model.canSeek)
        await model.seek(toLine: 3)
        XCTAssertEqual(spotify.seeks, [], "no seek without the opt-in")

        settings.allowSeeking = true
        auth.installForTesting(SpotifyTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture,
                                             scope: (AppConfig.spotifyScopes + [AppConfig.spotifySeekScope]).joined(separator: " ")))
        XCTAssertTrue(model.canSeek)
        await model.seek(toLine: 3)
        XCTAssertEqual(spotify.seeks.count, 1)
        XCTAssertEqual(spotify.seeks[0], 17.05, accuracy: 0.001)
        XCTAssertEqual(model.snapshot.currentLine, 3, "moves right away")
    }

    func testSeekErrorIsReported() async {
        settings.allowSeeking = true
        auth.installForTesting(SpotifyTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture,
                                             scope: AppConfig.spotifySeekScope))
        lyrics.set(.synced(makeTimeline()), for: "a")
        spotify.play(makeTrack("a"), at: 0)
        spotify.seekError = SpotifyAPIError.premiumRequired
        await model.pollOnce()
        await waitUntil { self.model.snapshot.timeline != nil }
        await model.seek(toLine: 2)
        XCTAssertEqual(model.seekMessage, SpotifyAPIError.premiumRequired.errorDescription)
    }

    func testSignOutClearsTheSnapshotAndStopsPolling() async {
        spotify.play(makeTrack("a"), at: 0)
        model.setActive(true, client: "test")
        XCTAssertTrue(model.isRunning)
        await waitUntil { self.model.snapshot.track != nil }
        auth.signOut()
        await waitUntil { !self.model.snapshot.isSignedIn }
        XCTAssertNil(model.snapshot.track)
        XCTAssertFalse(model.isRunning)
    }

    func testPollingOnlyWhileAClientIsActive() async {
        XCTAssertFalse(model.isRunning)
        model.setActive(true, client: "phone")
        model.setActive(true, client: "carplay")
        model.setActive(false, client: "phone")
        XCTAssertTrue(model.isRunning)
        model.setActive(false, client: "carplay")
        XCTAssertFalse(model.isRunning)
    }

    func testDemoModeUsesTheBuiltInSong() async {
        settings.demoMode = true
        XCTAssertTrue(model.isDemo)
        await model.pollOnce()
        XCTAssertEqual(model.snapshot.track, DemoSong.track)
        XCTAssertEqual(spotify.polls, 0, "Spotify isn't asked in demo mode")
        await waitUntil { self.model.snapshot.timeline != nil }
        XCTAssertTrue(model.canSeek, "the demo can always seek")
        await model.seek(toLine: 4)
        XCTAssertEqual(demo.position, DemoSong.timeline.lines[4].time + 0.05, accuracy: 0.01)

        settings.demoMode = false
        XCTAssertFalse(model.isDemo)
        XCTAssertNil(model.snapshot.track)
    }

    func testChoosingLyricsMarksThemAsChosen() async throws {
        spotify.play(makeTrack("a"), at: 0)
        await model.pollOnce()
        let candidates = try await model.lyricCandidates()
        try await model.chooseLyrics(candidates[0])
        XCTAssertEqual(model.snapshot.lyrics, .loaded(.plain(["picked"])))
        XCTAssertTrue(model.snapshot.lyricsChosenByUser)
        try await model.resetLyricsChoice()
        XCTAssertFalse(model.snapshot.lyricsChosenByUser)
    }

    func testDeleteAllDataSignsOutAndClearsSettings() async {
        settings.globalOffset = 1
        settings.trackOffsets = ["x": 0.5]
        settings.keepScreenAwake = true
        spotify.play(makeTrack("a"), at: 0)
        await model.pollOnce()

        await model.deleteAllData()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertEqual(settings.globalOffset, 0)
        XCTAssertEqual(settings.trackOffsets, [:])
        XCTAssertFalse(settings.keepScreenAwake)
        XCTAssertNil(model.snapshot.track)
    }

    func testDeleteAllDataClearsTheLyricsCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let synced = #"{"id":7,"trackName":"Song a","artistName":"Artist","duration":60,"syncedLyrics":"[00:01.00]hi"}"#
        let store = LyricsStore(client: LRCLibClient(http: StubHTTP { _ in (200, Data(synced.utf8)) }), directory: directory)
        let clock = self.clock!
        let model = NowPlayingModel(settings: settings, auth: auth, dependencies: .init(
            spotify: spotify, lyrics: store, store: store, demo: demo, demoLyrics: DemoLyricsProvider(), now: { clock.now }))
        _ = try await store.lyrics(for: makeTrack("a"))
        let before = await model.cachedSongCount()
        XCTAssertEqual(before, 1)
        await model.deleteAllData()
        let after = await model.cachedSongCount()
        XCTAssertEqual(after, 0)
    }
}
