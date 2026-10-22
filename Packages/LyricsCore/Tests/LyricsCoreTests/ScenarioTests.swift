import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LyricsCore

/// Real-world situations driven through the public API: Spotify's JSON goes through
/// `SpotifyWebAPI`, the resulting samples through `NowPlayingEngine`.
final class ScenarioTests: XCTestCase {
    // MARK: Helpers

    func item(id: String? = "a", name: String = "A", artists: [String] = ["Artist"], durationMs: Int = 200_000,
              type: String = "track", isLocal: Bool = false) -> String {
        let idField = id.map { "\"\($0)\"" } ?? "null"
        let artistList = artists.map { "{\"name\":\"\($0)\"}" }.joined(separator: ",")
        return """
        {"id":\(idField),"type":"\(type)","name":"\(name)","duration_ms":\(durationMs),"is_local":\(isLocal),
         "artists":[\(artistList)],"album":{"name":"Album","images":[]}}
        """
    }

    func body(item: String?, progressMs: Int, playing: Bool = true, type: String = "track") -> String {
        """
        {"progress_ms":\(progressMs),"is_playing":\(playing),"currently_playing_type":"\(type)","item":\(item ?? "null")}
        """
    }

    func api(_ http: StubHTTP) -> SpotifyWebAPI {
        SpotifyWebAPI(http: http, now: { 0 }) { _ in "token" }
    }

    func sample(_ json: String) async throws -> PlaybackSample {
        try await api(StubHTTP { _ in (200, Data(json.utf8), [:]) }).currentlyPlaying()
    }

    // MARK: Podcasts, ads, local files, private session

    func testPodcastEpisodeShowsNothingAndLoadsNoLyrics() async throws {
        var engine = NowPlayingEngine(isSignedIn: true)
        let episode = try await sample(body(item: item(id: "ep1", name: "Episode", type: "episode"), progressMs: 5000, type: "episode"))
        XCTAssertNil(episode.track)
        XCTAssertEqual(episode.kind, .episode)
        XCTAssertEqual(engine.apply(episode, at: 10), [])
        XCTAssertNil(engine.snapshot.track)
        XCTAssertEqual(engine.snapshot.lyrics, .none)
    }

    func testAdBreakInTheMiddleOfASongKeepsTheSongAfterOneAnswer() async throws {
        var engine = NowPlayingEngine(isSignedIn: true)
        let song = try await sample(body(item: item(), progressMs: 30_000))
        _ = engine.apply(song, at: 100)
        engine.lyricsLoaded(.synced(makeTimeline()), for: "a", at: 100)

        let ad = try await sample(body(item: nil, progressMs: 0, type: "ad"))
        XCTAssertNil(ad.track)
        XCTAssertEqual(ad.kind, .ad)
        _ = engine.apply(ad, at: 101.5)
        XCTAssertEqual(engine.snapshot.track?.id, "a", "one empty answer must not blank the lyrics")
        _ = engine.apply(ad, at: 103)
        XCTAssertNil(engine.snapshot.track, "a second empty answer in a row ends the song")

        // After the ad the same song resumes: it loads again, from the start of the lookup.
        let effects = engine.apply(try await sample(body(item: item(), progressMs: 31_000)), at: 130)
        XCTAssertEqual(effects.first, .loadLyrics(song.track!))
    }

    func testLocalFileWithoutIDGetsAStableKey() async throws {
        let local = try await sample(body(item: item(id: nil, name: "My Demo", artists: ["Me"], isLocal: true), progressMs: 1000))
        XCTAssertEqual(local.track?.id, "local:Me-My Demo")
        var engine = NowPlayingEngine(isSignedIn: true)
        XCTAssertEqual(engine.apply(local, at: 10), [.loadLyrics(local.track!), .prefetchUpcoming])

        // No artist and no ID at all: still a track, keyed by title.
        let bare = try await sample(body(item: item(id: nil, name: "Untitled", artists: [], isLocal: true), progressMs: 0))
        XCTAssertEqual(bare.track?.title, "Untitled")
        // No ID and not local: nothing to key on, so no track (and no crash).
        let unknown = try await sample(body(item: item(id: nil, name: "Mystery", isLocal: false), progressMs: 0))
        XCTAssertNil(unknown.track)
    }

    func testPrivateSessionAnswers() async throws {
        // 204 No Content.
        let empty = try await api(StubHTTP { _ in (204, Data(), [:]) }).currentlyPlaying()
        XCTAssertNil(empty.track)
        XCTAssertFalse(empty.isPlaying)
        // 200 with no item.
        let noItem = try await sample(#"{"is_playing":true,"currently_playing_type":"unknown","item":null}"#)
        XCTAssertNil(noItem.track)
        XCTAssertEqual(noItem.kind, .unknown)
        XCTAssertEqual(empty.kind, .nothing)
        // Neither flips a playing song to "nothing" on the first answer; two do.
        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(try await sample(body(item: item(), progressMs: 5000)), at: 10)
        _ = engine.apply(empty, at: 11.5)
        XCTAssertNotNil(engine.snapshot.track)
        _ = engine.apply(noItem, at: 13)
        XCTAssertNil(engine.snapshot.track)
    }

    // MARK: Token expiry, offline

    func testTokenExpiresMidSessionAndIsRefreshedOnce() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _refreshes = 0
            func refreshed() { lock.lock(); _refreshes += 1; lock.unlock() }
            var refreshes: Int { lock.lock(); defer { lock.unlock() }; return _refreshes }
        }
        let counter = Counter()
        let json = body(item: item(), progressMs: 40_000)
        let http = StubHTTP { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" ? (200, Data(json.utf8), [:]) : (401, Data(), [:])
        }
        let api = SpotifyWebAPI(http: http, now: { 0 }) { force in
            if force { counter.refreshed() }
            return force ? "fresh" : "stale"
        }
        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(try await api.currentlyPlaying(), at: 50)
        XCTAssertEqual(counter.refreshes, 1)
        XCTAssertEqual(engine.snapshot.track?.id, "a")
        XCTAssertFalse(engine.needsSignIn)
        XCTAssertNil(engine.snapshot.problem)
    }

    func testRevokedTokenEndsInSignIn() async {
        let api = SpotifyWebAPI(http: StubHTTP { _ in (401, Data(), [:]) }, now: { 0 }) { _ in "token" }
        var engine = NowPlayingEngine(isSignedIn: true)
        for i in 0..<NowPlayingEngine.maxUnauthorized {
            do { _ = try await api.currentlyPlaying() } catch { _ = engine.pollFailed(error, at: Double(i) * 10) }
        }
        XCTAssertTrue(engine.needsSignIn)
    }

    func testOfflineThroughATunnelKeepsFollowingThenRecovers() async throws {
        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(try await sample(body(item: item(), progressMs: 10_000)), at: 100)
        engine.lyricsLoaded(.synced(makeTimeline()), for: "a", at: 100)

        let offline = api(StubHTTP { _ in throw URLError(.notConnectedToInternet) })
        var time = 101.5
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            do { _ = try await offline.currentlyPlaying() } catch { waits.append(engine.pollFailed(error, at: time)) }
            time += waits.last ?? 1
            engine.tick(at: time)
        }
        XCTAssertEqual(engine.snapshot.problem, NowPlayingEngine.unreachableMessage)
        XCTAssertEqual(waits, waits.sorted(), "backoff never shortens while offline")
        XCTAssertLessThanOrEqual(waits.max() ?? 0, NowPlayingEngine.maxTransportBackoff)
        // The clock ran on: ~40 s into the song is past line 7 (starts at 37 s).
        XCTAssertEqual(engine.snapshot.currentLine, makeTimeline().index(at: engine.position(at: time) ?? 0))
        XCTAssertGreaterThanOrEqual(engine.snapshot.currentLine ?? 0, 6)

        // Signal is back: the next good poll clears the message and follows the real position.
        _ = engine.apply(try await sample(body(item: item(), progressMs: 10_000 + Int((time - 100) * 1000))), at: time)
        XCTAssertNil(engine.snapshot.problem)
        XCTAssertEqual(engine.snapshot.track?.id, "a")
    }

    // MARK: Song length

    func testVeryShortTrackEndsAndNextTrackIsPickedUpQuickly() async throws {
        let jingle = item(id: "short", name: "Jingle", durationMs: 12_000)
        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(try await sample(body(item: jingle, progressMs: 500)), at: 100)
        engine.lyricsLoaded(.synced(LyricsTimeline(lines: [LyricLine(time: 1, text: "a"), LyricLine(time: 5, text: "b"), LyricLine(time: 9, text: "c")])),
                            for: "short", at: 100)
        engine.tick(at: 106)
        XCTAssertEqual(engine.snapshot.currentLine, 1)
        // The poll is never scheduled more than the steady interval away, and never in a tight loop.
        for t in stride(from: 100.0, to: 112, by: 0.5) {
            let delay = engine.nextPollDelay(at: t)
            XCTAssertGreaterThanOrEqual(delay, NowPlayingEngine.fastPollInterval * 0.75 - 0.0001, "t=\(t)")
            XCTAssertLessThanOrEqual(delay, NowPlayingEngine.playingPollInterval + 0.0001, "t=\(t)")
        }
        // Past the end, then the next song.
        engine.tick(at: 120)
        XCTAssertEqual(engine.snapshot.currentLine, 2, "stays on the last line at the end")
        let next = try await sample(body(item: item(id: "next", name: "Next"), progressMs: 300))
        XCTAssertEqual(engine.apply(next, at: 120.5).first, .loadLyrics(next.track!))
    }

    func testVeryLongTrackStaysInSyncAfterTwentyMinutes() async throws {
        let mix = item(id: "mix", name: "DJ Mix", durationMs: 4_200_000)
        let lrc = (0..<420).map { String(format: "[%02d:%02d:%02d.00]line %d", $0 * 10 / 3600, ($0 * 10 % 3600) / 60, $0 * 10 % 60, $0) }.joined(separator: "\n")
        let timeline = LyricsTimeline(lrc: lrc)
        XCTAssertEqual(timeline.lines.count, 420)

        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(try await sample(body(item: mix, progressMs: 1_300_000)), at: 5000)
        engine.lyricsLoaded(.synced(timeline), for: "mix", at: 5000)
        engine.tick(at: 5000)
        XCTAssertEqual(engine.snapshot.currentLine, 130)
        // 50 more minutes with a poll every 1.5 s agreeing with the clock: no drift, no stall flag.
        var t = 5000.0
        while t < 5000 + 3000 {
            t += 1.5
            _ = engine.apply(try await sample(body(item: mix, progressMs: 1_300_000 + Int((t - 5000) * 1000))), at: t)
        }
        XCTAssertFalse(engine.isStalled)
        XCTAssertEqual(engine.snapshot.currentLine, min(419, (1300 + 3000) / 10))
    }

    // MARK: Non-Latin text

    func testNonLatinTitlesArtistsAndLyricsSurviveTheWholePath() async throws {
        let cases: [(title: String, artist: String, lyric: String)] = [
            ("夜に駆ける", "YOASOBI", "沈むように溶けてゆくように"),
            ("حبيبي يا نور العين", "عمرو دياب", "حبيبي يا نور العين"),
            ("Привет 🌍", "Кино", "Ночь коротка 🔥"),
            ("서울의 밤", "김광석", "사랑해"),
        ]
        for (index, c) in cases.enumerated() {
            let json = body(item: item(id: "n\(index)", name: c.title, artists: [c.artist], durationMs: 200_000), progressMs: 1000)
            let parsed = try await sample(json)
            XCTAssertEqual(parsed.track?.title, c.title)
            XCTAssertEqual(parsed.track?.artists, [c.artist])

            let record = LRCLibRecord(id: index, trackName: c.title, artistName: c.artist, duration: 200, syncedLyrics: "[00:02.00]\(c.lyric)")
            XCTAssertNotNil(LRCLibClient.score(record, for: parsed.track!), c.title)

            var engine = NowPlayingEngine(isSignedIn: true)
            _ = engine.apply(parsed, at: 10)
            engine.lyricsLoaded(Lyrics(record: record), for: "n\(index)", at: 10)
            engine.tick(at: 12)
            XCTAssertEqual(engine.snapshot.currentLine, 0)
            XCTAssertEqual(engine.snapshot.timeline?.lines.first?.text, c.lyric)
        }
    }

    // MARK: Repeat-one, crossfade

    func testRepeatOneWrapsToZeroWithoutReloadingLyrics() async throws {
        let song = item(id: "loop", name: "Loop", durationMs: 60_000)
        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(try await sample(body(item: song, progressMs: 0)), at: 100)
        engine.lyricsLoaded(.synced(makeTimeline()), for: "loop", at: 100)
        for lap in 1...3 {
            let end = 100 + Double(lap) * 60
            // Ordinary polls every 1.5 s through the lap, as the app does.
            var t = end - 60 + 1.5
            while t < end - 0.5 {
                _ = engine.apply(try await sample(body(item: song, progressMs: Int((t - (end - 60)) * 1000))), at: t)
                t += 1.5
            }
            engine.tick(at: end - 0.5)
            XCTAssertEqual(engine.snapshot.currentLine, 9, "lap \(lap)")
            // Spotify reports the wrap: same ID, position near 0.
            let effects = engine.apply(try await sample(body(item: song, progressMs: 300)), at: end + 0.3)
            XCTAssertEqual(effects, [], "repeat must not reload lyrics (lap \(lap))")
            guard case .loaded = engine.snapshot.lyrics else { return XCTFail("lyrics kept") }
            XCTAssertNil(engine.snapshot.currentLine)
            // The clock restarted: it is at the start, not stuck at the end.
            XCTAssertEqual(engine.playbackPosition(at: end + 0.3) ?? -1, 0.3, accuracy: 0.05)
        }
    }

    func testCrossfadeStartsTheNextSongBeforeTheOldOneEnds() async throws {
        let first = item(id: "one", name: "One", durationMs: 120_000)
        let second = item(id: "two", name: "Two", durationMs: 180_000)
        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(try await sample(body(item: first, progressMs: 100_000)), at: 100)
        engine.lyricsLoaded(.synced(makeTimeline()), for: "one", at: 100)
        engine.tick(at: 105)
        XCTAssertEqual(engine.snapshot.currentLine, 9)

        // Eight seconds before the end Spotify already reports the next song, at position 0.4 s.
        let next = try await sample(body(item: second, progressMs: 400))
        XCTAssertEqual(engine.apply(next, at: 112), [.loadLyrics(next.track!), .prefetchUpcoming])
        XCTAssertEqual(engine.snapshot.track?.id, "two")
        XCTAssertNil(engine.snapshot.currentLine)
        XCTAssertEqual(engine.snapshot.lyrics, .loading)

        // The old song's lyrics finishing late are ignored; the new song's apply.
        engine.lyricsLoaded(.synced(makeTimeline()), for: "one", at: 112.5)
        XCTAssertEqual(engine.snapshot.lyrics, .loading)
        engine.lyricsLoaded(.synced(makeTimeline(count: 3)), for: "two", at: 113)
        XCTAssertEqual(engine.snapshot.timeline?.lines.count, 3)
        // And the old song's end time no longer triggers early polls for the new one.
        XCTAssertFalse(engine.takeEarlyPoll(at: 125))
    }
}

/// How a request's timing window is narrowed when the HTTP client can report one.
final class RequestTimingTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    /// Takes 3 s overall (a slow handshake), of which the server worked for 0.2 s
    /// starting 2.5 s in.
    struct SlowHandshake: HTTPClient {
        let clock: Clock
        let window: (Date) -> HTTPExchangeWindow?
        let body = Data(#"{"progress_ms":1000,"is_playing":true,"item":{"id":"a","name":"A","duration_ms":5000}}"#.utf8)

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, response, _) = try await sendTimed(request)
            return (data, response)
        }

        func sendTimed(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, HTTPExchangeWindow?) {
            let began = Date()
            clock.advance(3)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response, window(began))
        }
    }

    func testWindowNarrowsTheMeasurementToTheServersTime() async throws {
        let clock = Clock()
        let http = SlowHandshake(clock: clock) { began in
            HTTPExchangeWindow(requestEnd: began.addingTimeInterval(2.5), responseStart: began.addingTimeInterval(2.7))
        }
        let sample = try await SpotifyWebAPI(http: http, now: { clock.now() }) { _ in "t" }.currentlyPlaying()
        XCTAssertEqual(sample.requestStart ?? -1, 2.5, accuracy: 0.05)
        XCTAssertEqual(sample.requestEnd ?? -1, 2.7, accuracy: 0.05)
    }

    func testWithoutMetricsTheFullRoundTripIsUsed() async throws {
        let clock = Clock()
        let http = SlowHandshake(clock: clock) { _ in nil }
        let sample = try await SpotifyWebAPI(http: http, now: { clock.now() }) { _ in "t" }.currentlyPlaying()
        XCTAssertEqual(sample.requestStart ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(sample.requestEnd ?? -1, 3, accuracy: 0.0001)
    }

    func testImplausibleWindowsAreClampedToTheRoundTrip() async throws {
        let clock = Clock()
        // A wall clock that jumped: dates far outside the exchange.
        let http = SlowHandshake(clock: clock) { began in
            HTTPExchangeWindow(requestEnd: began.addingTimeInterval(-50), responseStart: began.addingTimeInterval(80))
        }
        let sample = try await SpotifyWebAPI(http: http, now: { clock.now() }) { _ in "t" }.currentlyPlaying()
        XCTAssertGreaterThanOrEqual(sample.requestStart ?? -1, 0)
        XCTAssertLessThanOrEqual(sample.requestEnd ?? 99, 3)
        XCTAssertLessThanOrEqual(sample.requestStart ?? 99, sample.requestEnd ?? -1)

        // Reversed dates are ignored.
        let reversed = SlowHandshake(clock: clock) { began in
            HTTPExchangeWindow(requestEnd: began.addingTimeInterval(2), responseStart: began.addingTimeInterval(1))
        }
        let again = try await SpotifyWebAPI(http: reversed, now: { clock.now() }) { _ in "t" }.currentlyPlaying()
        XCTAssertEqual((again.requestEnd ?? 0) - (again.requestStart ?? 0), 3, accuracy: 0.0001)
    }
}

final class PlayingKindTests: XCTestCase {
    func kind(_ json: String) throws -> PlayingKind { try PlaybackSample.decode(Data(json.utf8)).kind }

    func testKindsFromCurrentlyPlayingType() throws {
        XCTAssertEqual(try kind(#"{"is_playing":true,"currently_playing_type":"track","item":{"id":"a","name":"A"}}"#), .track)
        XCTAssertEqual(try kind(#"{"is_playing":true,"item":{"id":"a","name":"A"}}"#), .track, "type is optional")
        XCTAssertEqual(try kind(#"{"is_playing":true,"currently_playing_type":"episode","item":{"id":"e","name":"E","type":"episode"}}"#), .episode)
        XCTAssertEqual(try kind(#"{"is_playing":true,"currently_playing_type":"ad","item":null}"#), .ad)
        XCTAssertEqual(try kind(#"{"is_playing":true,"currently_playing_type":"unknown","item":null}"#), .unknown)
        XCTAssertEqual(try kind(#"{"is_playing":false,"currently_playing_type":"track","item":null}"#), .nothing)
        // A track Spotify gives no ID for (and that isn't a local file) can't be used.
        XCTAssertEqual(try kind(#"{"is_playing":true,"currently_playing_type":"track","item":{"name":"Mystery"}}"#), .unknown)
    }

    func testPlaybackSampleDefaultsKeepOldCallersWorking() {
        XCTAssertEqual(PlaybackSample(track: nil, position: 0, isPlaying: false).kind, .nothing)
        XCTAssertEqual(PlaybackSample(track: makeTrack(), position: 0, isPlaying: true).kind, .track)
        XCTAssertEqual(PlaybackSample.nothing.kind, .nothing)
    }
}

final class AccountTests: XCTestCase {
    func testMeDecodesNameAndProduct() async throws {
        let http = StubHTTP { request in
            request.path == "/v1/me"
                ? (200, Data(#"{"id":"u123","display_name":"Maria Çelik","product":"premium","country":"TR"}"#.utf8), [:])
                : (404, Data(), [:])
        }
        let profile = try await SpotifyWebAPI(http: http) { _ in "t" }.me()
        XCTAssertEqual(profile, SpotifyProfile(id: "u123", displayName: "Maria Çelik", product: "premium"))
        XCTAssertEqual(profile.label, "Maria Çelik")
        XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testMeWithoutNameOrProductFallsBackToTheID() async throws {
        let http = StubHTTP { _ in (200, Data(#"{"id":"u123","display_name":null}"#.utf8), [:]) }
        let profile = try await SpotifyWebAPI(http: http) { _ in "t" }.me()
        XCTAssertNil(profile.product)
        XCTAssertEqual(profile.label, "u123")
        XCTAssertEqual(SpotifyProfile(displayName: "  ").label, "your Spotify account")
    }

    func testMeErrors() async {
        await assertThrows(SpotifyAPIError.unauthorized) {
            _ = try await SpotifyWebAPI(http: StubHTTP { _ in (401, Data(), [:]) }) { _ in "t" }.me()
        }
        await assertThrows(SpotifyAPIError.rateLimited(retryAfter: 7)) {
            _ = try await SpotifyWebAPI(http: StubHTTP { _ in (429, Data(), ["Retry-After": "7"]) }) { _ in "t" }.me()
        }
    }
}
