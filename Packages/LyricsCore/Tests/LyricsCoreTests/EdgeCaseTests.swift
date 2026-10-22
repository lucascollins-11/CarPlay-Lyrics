import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LyricsCore

// Edge cases from qa/edge-cases.md (EC numbers) plus odd real-world data:
// non-Latin text, very short and very long songs, and malformed LRC.

final class LRCOdditiesTests: XCTestCase {
    // EC21
    func testHourTimestamps() {
        XCTAssertEqual(LRCParser.parseTimestamp("01:02:03.50"), 3723.5)
        XCTAssertEqual(LRCParser.parseTimestamp("0:00:01.00"), 1)
        // Without a fraction the third field is still hundredths (`mm:ss:xx`).
        XCTAssertEqual(LRCParser.parseTimestamp("01:05:50"), 65.5)
        XCTAssertNil(LRCParser.parseTimestamp("01:x2:03.50"))
        XCTAssertNil(LRCParser.parseTimestamp("01:02:03.5.0"))

        let lines = LRCParser.parse("""
        [00:59:58.00]before the hour
        [01:00:02.25]after the hour
        """)
        XCTAssertEqual(lines.map(\.time), [3598, 3602.25])
    }

    // EC22
    func testCRLFAndBareCRInSyncedLyrics() {
        let crlf = LRCParser.parse("[00:01.00]one\r\n[00:02.00]two\r\n\r\n[00:03.00]three")
        XCTAssertEqual(crlf.map(\.text), ["one", "two", "three"])
        let cr = LRCParser.parse("[00:01.00]one\r[00:02.00]two")
        XCTAssertEqual(cr.map(\.text), ["one", "two"])
    }

    // EC22
    func testCRLFInPlainLyricsDoesNotAddBlankLines() {
        XCTAssertEqual(Lyrics(record: LRCLibRecord(id: 1, plainLyrics: "a\r\nb\r\n\r\nc")), .plain(["a", "b", "", "c"]))
        XCTAssertEqual(Lyrics(record: LRCLibRecord(id: 1, plainLyrics: "a\rb")), .plain(["a", "b"]))
    }

    func testByteOrderMarkDoesNotHideFirstLine() {
        let lines = LRCParser.parse("\u{FEFF}[00:01.00]first\n[00:02.00]second")
        XCTAssertEqual(lines.map(\.text), ["first", "second"])
    }

    func testSpacesInsideTagsAndTagOnlyLines() {
        let lines = LRCParser.parse("[ 00:01.00 ]spaced\n[00:02.00]\n[00:03.00]   ")
        XCTAssertEqual(lines.map(\.text), ["spaced", "", ""])
        XCTAssertTrue(lines[1].isGap && lines[2].isGap)
    }

    func testMalformedTagsAreSkippedNotCrashing() {
        let lines = LRCParser.parse("""
        [00:01.00
        [abc]text
        []empty
        [00:]x
        [:00]y
        [99999999999999999999:00]huge
        [00:02.00]ok
        """)
        XCTAssertEqual(lines.map(\.text), ["ok"])
    }

    func testOnlyMetadataGivesNoLines() {
        XCTAssertTrue(LRCParser.parse("[ar:Artist]\n[ti:Title]\n[length:03:20]").isEmpty)
        XCTAssertEqual(Lyrics(record: LRCLibRecord(id: 1, syncedLyrics: "[ar:Artist]\n[ti:Title]")), .notFound)
    }
}

final class DegenerateLRCTests: XCTestCase {
    // EC9
    func testAllLinesAtZeroFallsBackToPlainLyrics() {
        let lrc = "[00:00.00]one\n[00:00.00]two\n[00:00.00]three\n[00:00.00]four"
        XCTAssertEqual(Lyrics(record: LRCLibRecord(id: 1, plainLyrics: "one\ntwo\nthree\nfour", syncedLyrics: lrc)),
                       .plain(["one", "two", "three", "four"]))
        // No plain text in the record: the words still show, unsynced.
        XCTAssertEqual(Lyrics(record: LRCLibRecord(id: 1, syncedLyrics: lrc)), .plain(["one", "two", "three", "four"]))
    }

    func testMostLinesSharingOneTimeIsDegenerate() {
        let lrc = "[00:00.00]a\n[00:00.00]b\n[00:00.00]c\n[00:10.00]d\n[00:20.00]e"
        XCTAssertFalse(Lyrics(record: LRCLibRecord(id: 1, syncedLyrics: lrc)).isSynced)
    }

    func testLinesPastTheEndOfTheSongAreDegenerate() {
        let lrc = "[00:10.00]a\n[00:20.00]b\n[05:00.00]from the extended mix"
        // Record without a duration: the track's length decides.
        XCTAssertFalse(Lyrics(record: LRCLibRecord(id: 1, syncedLyrics: lrc), trackDuration: 200).isSynced)
        XCTAssertTrue(Lyrics(record: LRCLibRecord(id: 1, syncedLyrics: lrc), trackDuration: 301).isSynced)
        // The record's own duration wins over the track's.
        XCTAssertFalse(Lyrics(record: LRCLibRecord(id: 1, duration: 200, syncedLyrics: lrc), trackDuration: 400).isSynced)
        // Unknown length on both sides: trust the timestamps.
        XCTAssertTrue(Lyrics(record: LRCLibRecord(id: 1, syncedLyrics: lrc)).isSynced)
        // A trailing gap marker just after the end is fine; only sung lines count.
        let outro = "[00:10.00]a\n[00:20.00]b\n[03:25.00]"
        XCTAssertTrue(Lyrics(record: LRCLibRecord(id: 1, syncedLyrics: outro), trackDuration: 200).isSynced)
    }

    func testNormalSongsAreNotFlagged() {
        // A chorus repeated at different times and a duet line sharing a timestamp are normal.
        let lrc = "[00:10.00][00:40.00][01:10.00]Chorus\n[00:20.00]Verse\n[00:50.00]Him\n[00:50.00]Her\n[01:00.00]Bridge"
        XCTAssertTrue(Lyrics(record: LRCLibRecord(id: 1, duration: 90, syncedLyrics: lrc)).isSynced)
        // Two lines at one time in a two-line song: too little to judge.
        XCTAssertTrue(Lyrics(record: LRCLibRecord(id: 1, syncedLyrics: "[00:00.00]a\n[00:00.00]b")).isSynced)
    }

    func testDegenerateSyncedLosesToGoodSyncedInSearch() {
        let track = makeTrack(title: "Song", artists: ["Artist"], duration: 200)
        let records = [
            LRCLibRecord(id: 1, trackName: "Song", artistName: "Artist", duration: 200,
                         syncedLyrics: "[00:00.00]a\n[00:00.00]b\n[00:00.00]c"),
            LRCLibRecord(id: 2, trackName: "Song", artistName: "Artist", duration: 202, syncedLyrics: "[00:05.00]a\n[00:10.00]b\n[00:15.00]c"),
        ]
        XCTAssertEqual(LRCLibClient.bestMatch(in: records, for: track)?.id, 2)
    }

    func testDegenerateExactHitDoesNotEndTheLookup() async throws {
        let track = makeTrack(title: "Song", artists: ["Artist"], duration: 200)
        let broken = #"{"id":1,"trackName":"Song","artistName":"Artist","duration":200,"syncedLyrics":"[00:00.00]a\n[00:00.00]b\n[00:00.00]c"}"#
        let good = #"{"id":2,"trackName":"Song","artistName":"Artist","duration":200,"syncedLyrics":"[00:05.00]a\n[00:10.00]b"}"#
        let http = StubHTTP { request in
            request.path == "/api/get" ? (200, json(broken), [:]) : (200, json("[\(good)]"), [:])
        }
        let record = try await LRCLibClient(http: http).lyrics(for: track)
        XCTAssertEqual(record?.id, 2)
    }
}

final class MatchingEdgeCaseTests: XCTestCase {
    // EC8
    func testExactTitleBeatsLongerTitleWithSyncedLyrics() {
        let track = makeTrack(title: "Stay", artists: ["Artist"], duration: 200)
        let records = [
            LRCLibRecord(id: 1, trackName: "Stay With Me", artistName: "Artist", duration: 201, syncedLyrics: "[00:01.00]x"),
            LRCLibRecord(id: 2, trackName: "Stay", artistName: "Artist", duration: 200, plainLyrics: "y"),
        ]
        XCTAssertEqual(LRCLibClient.bestMatch(in: records, for: track)?.id, 2)
        XCTAssertEqual(LRCLibClient.ranked(records, for: track).map(\.id), [2, 1])
    }

    func testExactSyncedStillBeatsExactPlain() {
        let track = makeTrack(title: "Stay", artists: ["Artist"], duration: 200)
        let records = [
            LRCLibRecord(id: 1, trackName: "Stay", artistName: "Artist", duration: 200, plainLyrics: "y"),
            LRCLibRecord(id: 2, trackName: "Stay", artistName: "Artist", duration: 203, syncedLyrics: "[00:01.00]x"),
        ]
        XCTAssertEqual(LRCLibClient.bestMatch(in: records, for: track)?.id, 2)
    }

    func testPrefixMatchIsUsedWhenNothingExactExists() {
        let track = makeTrack(title: "Stay", artists: ["Artist"], duration: 200)
        let records = [LRCLibRecord(id: 1, trackName: "Stay (Interlude)", artistName: "Artist", duration: 200, syncedLyrics: "[00:01.00]x")]
        XCTAssertEqual(LRCLibClient.bestMatch(in: records, for: track)?.id, 1)
    }

    // EC17
    func testAutomaticLookupFallsBackToFreeTextSearch() async throws {
        let track = makeTrack(title: "Song", artists: ["Artist"], duration: 200)
        let hit = #"{"id":5,"trackName":"Song","artistName":"Artist & Friend","duration":200,"syncedLyrics":"[00:01.00]x"}"#
        let http = StubHTTP { request in
            if request.path == "/api/get" { return (404, Data(), [:]) }
            return request.query["q"] != nil ? (200, json("[\(hit)]"), [:]) : (200, json("[]"), [:])
        }
        let record = try await LRCLibClient(http: http).lyrics(for: track)
        XCTAssertEqual(record?.id, 5)
        XCTAssertEqual(http.requests.last?.query["q"], "Song Artist")
    }

    func testFreeTextResultsAreStillFilteredByArtist() async throws {
        let track = makeTrack(title: "Song", artists: ["Artist"], duration: 200)
        let other = #"{"id":5,"trackName":"Song","artistName":"Somebody Else","duration":200,"syncedLyrics":"[00:01.00]x"}"#
        let http = StubHTTP { request in
            if request.path == "/api/get" { return (404, Data(), [:]) }
            return request.query["q"] != nil ? (200, json("[\(other)]"), [:]) : (200, json("[]"), [:])
        }
        let record = try await LRCLibClient(http: http).lyrics(for: track)
        XCTAssertNil(record)
    }

    func testNoFreeTextSearchWhenTitleSearchFoundSyncedLyrics() async throws {
        let track = makeTrack(title: "Song", artists: ["Artist"], duration: 200)
        let hit = #"{"id":5,"trackName":"Song","artistName":"Artist","duration":200,"syncedLyrics":"[00:01.00]x"}"#
        let http = StubHTTP { request in
            request.path == "/api/get" ? (404, Data(), [:]) : (200, json("[\(hit)]"), [:])
        }
        _ = try await LRCLibClient(http: http).lyrics(for: track)
        XCTAssertNil(http.requests.last?.query["q"])
    }

    func testFailedFreeTextSearchAfterEmptyTitleSearchMeansNotFound() async throws {
        let track = makeTrack(title: "Song", artists: ["Artist"], duration: 200)
        let http = StubHTTP { request in
            if request.path == "/api/get" { return (404, Data(), [:]) }
            return request.query["q"] != nil ? (503, Data(), [:]) : (200, json("[]"), [:])
        }
        let record = try await LRCLibClient(http: http).lyrics(for: track)
        XCTAssertNil(record)
    }

    func testPlainExactHitIsKeptWhenFreeTextOnlyFindsPlainToo() async throws {
        let track = makeTrack(title: "Song", artists: ["Artist"], duration: 200)
        let plain = #"{"id":1,"trackName":"Song","artistName":"Artist","duration":200,"plainLyrics":"p"}"#
        let http = StubHTTP { request in
            request.path == "/api/get" ? (200, json(plain), [:]) : (200, json("[]"), [:])
        }
        let record = try await LRCLibClient(http: http).lyrics(for: track)
        XCTAssertEqual(record?.id, 1)
    }
}

final class NonLatinTextTests: XCTestCase {
    func testJapaneseTitleAndArtistMatch() {
        let track = makeTrack(title: "夜に駆ける", artists: ["YOASOBI"], duration: 261)
        let records = [LRCLibRecord(id: 1, trackName: "夜に駆ける", artistName: "YOASOBI", duration: 261, syncedLyrics: "[00:01.00]沈むように溶けてゆくように")]
        XCTAssertEqual(LRCLibClient.bestMatch(in: records, for: track)?.id, 1)
    }

    func testKoreanAndCyrillicAndArabicText() {
        let lines = LRCParser.parse("[00:01.00]사랑해\n[00:02.00]Привет, мир\n[00:03.00]حبيبي يا نور العين")
        XCTAssertEqual(lines.map(\.text), ["사랑해", "Привет, мир", "حبيبي يا نور العين"])
        let track = makeTrack(title: "Кино", artists: ["Группа крови"], duration: 200)
        XCTAssertNotNil(LRCLibClient.score(LRCLibRecord(id: 1, trackName: "кино", artistName: "ГРУППА КРОВИ", duration: 200), for: track))
    }

    func testAccentsAndFullWidthFoldTogether() {
        let track = makeTrack(title: "Beyoncé Song", artists: ["Beyoncé"], duration: 200)
        XCTAssertNotNil(LRCLibClient.score(LRCLibRecord(id: 1, trackName: "Beyonce Song", artistName: "BEYONCE", duration: 200), for: track))
        XCTAssertEqual(TitleNormalizer.comparable("ＡＢＣ"), "abc")
        // Decomposed (e + combining accent) and precomposed é compare equal.
        XCTAssertEqual(TitleNormalizer.comparable("Cafe\u{301}"), TitleNormalizer.comparable("Café"))
    }

    func testEmojiAndSymbolOnlyTitles() {
        // A title made only of punctuation or emoji has nothing to compare: no match rather than a crash.
        let track = makeTrack(title: "♡", artists: ["Artist"], duration: 200)
        XCTAssertNil(LRCLibClient.score(LRCLibRecord(id: 1, trackName: "♡", artistName: "Artist", duration: 200), for: track))
        let lines = LRCParser.parse("[00:01.00]🔥🔥🔥 la la 🎶")
        XCTAssertEqual(lines.first?.text, "🔥🔥🔥 la la 🎶")
    }

    func testNonASCIIDigitsAreNotTimestamps() {
        // Full-width or Arabic-Indic digits must not parse as times.
        XCTAssertNil(LRCParser.parseTimestamp("０１:２３"))
        XCTAssertNil(LRCParser.parseTimestamp("00:٠١.٠٠"))
    }
}

final class SongLengthEdgeCaseTests: XCTestCase {
    func testVeryShortSong() {
        // A 6-second interlude with two lines.
        let lyrics = Lyrics(record: LRCLibRecord(id: 1, duration: 6, syncedLyrics: "[00:00.50]hey\n[00:03.00]ho"))
        guard case .synced(let timeline) = lyrics else { return XCTFail("expected synced") }
        XCTAssertNil(timeline.index(at: 0.2))
        XCTAssertEqual(timeline.index(at: 1), 0)
        XCTAssertEqual(timeline.index(at: 5.9), 1)
        XCTAssertNil(timeline.timeUntilNextLine(after: 5.9))
    }

    func testVeryLongSongWithHourTags() {
        // A 70-minute track (DJ mix, live album side) using `hh:mm:ss.xx`.
        let lrc = "[00:00:05.00]start\n[00:59:59.00]almost\n[01:05:00.00]late\n[01:09:30.00]end"
        let lyrics = Lyrics(record: LRCLibRecord(id: 1, duration: 4200, syncedLyrics: lrc))
        guard case .synced(let timeline) = lyrics else { return XCTFail("expected synced") }
        XCTAssertEqual(timeline.index(at: 3600), 1)
        XCTAssertEqual(timeline.index(at: 3900), 2)
        XCTAssertEqual(timeline.index(at: 4199), 3)
    }

    func testZeroDurationTrackSkipsLengthChecks() {
        // Spotify can report 0 for some podcasts/local files; don't throw lyrics away for it.
        let lrc = "[00:10.00]a\n[05:00.00]b"
        XCTAssertTrue(Lyrics(record: LRCLibRecord(id: 1, syncedLyrics: lrc), trackDuration: 0).isSynced)
        let track = makeTrack(title: "Song", artists: ["Artist"], duration: 0)
        XCTAssertTrue(LRCLibClient.durationMatches(LRCLibRecord(id: 1, duration: 300), track))
    }
}

final class LyricsStoreEdgeCaseTests: XCTestCase {
    let track = makeTrack(id: "abc123", title: "Song", artists: ["Artist"], duration: 200)
    let plain = #"{"id":1,"trackName":"Song","artistName":"Artist","duration":200,"plainLyrics":"words"}"#
    let synced = #"{"id":2,"trackName":"Song","artistName":"Artist","duration":200,"syncedLyrics":"[00:01.00]words"}"#
    var directory: URL!

    override func setUp() { directory = temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    /// A clock the test can move forward.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(days: Double) { lock.lock(); value += days * 24 * 3600; lock.unlock() }
    }

    func makeStore(_ http: StubHTTP, clock: Clock) -> LyricsStore {
        LyricsStore(client: LRCLibClient(http: http), directory: directory, now: { clock.now })
    }

    func plainOnly() -> StubHTTP {
        StubHTTP { [plain] request in request.path == "/api/get" ? (200, json(plain), [:]) : (200, json("[]"), [:]) }
    }

    func syncedNow() -> StubHTTP {
        StubHTTP { [synced] request in request.path == "/api/get" ? (200, json(synced), [:]) : (200, json("[]"), [:]) }
    }

    // EC16
    func testOldPlainEntryIsRecheckedAndUpgradedToSynced() async throws {
        let clock = Clock()
        _ = try await makeStore(plainOnly(), clock: clock).lyrics(for: track)

        clock.advance(days: 15)
        let later = syncedNow()
        let store = makeStore(later, clock: clock)
        // Shows the cached plain lyrics at once, without waiting for the network.
        let first = try await store.lyrics(for: track)
        XCTAssertEqual(first, .plain(["words"]))
        await store.waitForRechecks()
        XCTAssertGreaterThan(later.requests.count, 0)

        let upgraded = try await store.lyrics(for: track)
        XCTAssertTrue(upgraded.isSynced)
        // And it's on disk for the next launch.
        let offline = StubHTTP { _ in throw URLError(.notConnectedToInternet) }
        let relaunched = try await makeStore(offline, clock: clock).lyrics(for: track)
        XCTAssertTrue(relaunched.isSynced)
        XCTAssertEqual(offline.requests.count, 0)
    }

    func testRecentPlainEntryIsNotRechecked() async throws {
        let clock = Clock()
        _ = try await makeStore(plainOnly(), clock: clock).lyrics(for: track)
        clock.advance(days: 13)
        let http = syncedNow()
        let store = makeStore(http, clock: clock)
        _ = try await store.lyrics(for: track)
        await store.waitForRechecks()
        XCTAssertEqual(http.requests.count, 0)
    }

    func testRecheckThatFindsNothingBetterWaitsAnotherInterval() async throws {
        let clock = Clock()
        _ = try await makeStore(plainOnly(), clock: clock).lyrics(for: track)
        clock.advance(days: 15)
        let first = plainOnly()
        let store = makeStore(first, clock: clock)
        _ = try await store.lyrics(for: track)
        await store.waitForRechecks()
        XCTAssertGreaterThan(first.requests.count, 0)

        clock.advance(days: 1)
        let second = syncedNow()
        let relaunched = makeStore(second, clock: clock)
        _ = try await relaunched.lyrics(for: track)
        await relaunched.waitForRechecks()
        XCTAssertEqual(second.requests.count, 0)
    }

    func testOfflineRecheckKeepsTheEntryAndTriesNextLaunch() async throws {
        let clock = Clock()
        _ = try await makeStore(plainOnly(), clock: clock).lyrics(for: track)
        clock.advance(days: 15)
        let offline = StubHTTP { _ in throw URLError(.notConnectedToInternet) }
        let store = makeStore(offline, clock: clock)
        let lyrics = try await store.lyrics(for: track)
        await store.waitForRechecks()
        XCTAssertEqual(lyrics, .plain(["words"]))

        let online = syncedNow()
        let relaunched = makeStore(online, clock: clock)
        _ = try await relaunched.lyrics(for: track)
        await relaunched.waitForRechecks()
        XCTAssertGreaterThan(online.requests.count, 0)
    }

    func testUserPicksAreNeverRechecked() async throws {
        let clock = Clock()
        let store = makeStore(plainOnly(), clock: clock)
        _ = try await store.choose(LRCLibRecord(id: 1, trackName: "Song", artistName: "Artist", plainLyrics: "mine"), for: track)
        clock.advance(days: 100)
        let http = syncedNow()
        let relaunched = makeStore(http, clock: clock)
        let lyrics = try await relaunched.lyrics(for: track)
        await relaunched.waitForRechecks()
        XCTAssertEqual(lyrics, .plain(["mine"]))
        XCTAssertEqual(http.requests.count, 0)
    }

    func testSyncedEntriesAreNeverRechecked() async throws {
        let clock = Clock()
        _ = try await makeStore(syncedNow(), clock: clock).lyrics(for: track)
        clock.advance(days: 100)
        let http = plainOnly()
        let relaunched = makeStore(http, clock: clock)
        _ = try await relaunched.lyrics(for: track)
        await relaunched.waitForRechecks()
        XCTAssertEqual(http.requests.count, 0)
    }

    func testEntriesFromOlderVersionsWithoutDateAreRechecked() async throws {
        let legacy = try JSONEncoder().encode(LyricsStore.Entry(record: LRCLibRecord(id: 1, plainLyrics: "old"), chosenByUser: false))
        let clock = Clock()
        let http = syncedNow()
        let store = makeStore(http, clock: clock)
        try legacy.write(to: await store.fileURL(trackID: track.id))
        _ = try await store.lyrics(for: track)
        await store.waitForRechecks()
        XCTAssertGreaterThan(http.requests.count, 0)
    }

    func testUserPickDuringRecheckWins() async throws {
        let clock = Clock()
        _ = try await makeStore(plainOnly(), clock: clock).lyrics(for: track)
        clock.advance(days: 15)
        let slow = StubHTTP { [synced] request in
            Thread.sleep(forTimeInterval: 0.1)
            return request.path == "/api/get" ? (200, json(synced), [:]) : (200, json("[]"), [:])
        }
        let store = makeStore(slow, clock: clock)
        _ = try await store.lyrics(for: track)
        let picked = try await store.choose(LRCLibRecord(id: 9, plainLyrics: "picked"), for: track)
        await store.waitForRechecks()
        let after = try await store.lyrics(for: track)
        XCTAssertEqual(after, picked)
        let chosen = await store.isChosenByUser(track)
        XCTAssertTrue(chosen)
    }

    // EC19
    func testLongLocalFileKeysAreHashedToAValidFileName() async throws {
        let longID = "local:" + String(repeating: "Very Long Artist Name ", count: 10) + ":" + String(repeating: "Endless Title ", count: 10)
        let store = makeStore(syncedNow(), clock: Clock())
        let url = await store.fileURL(trackID: longID)
        XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 255)

        let other = await store.fileURL(trackID: longID + "x")
        XCTAssertNotEqual(url, other)
        // Short keys keep their readable names (existing caches stay valid).
        let short = await store.fileURL(trackID: "local:a:b")
        XCTAssertEqual(short.lastPathComponent, "x" + "local:a:b".utf8.map { String(format: "%02x", $0) }.joined() + ".json")
        let spotify = await store.fileURL(trackID: "4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(spotify.lastPathComponent, "4uLU6hMCjMI75M1A2tKUQC.json")

        // And the cache actually works for such a track.
        let longTrack = makeTrack(id: longID, title: "Song", artists: ["Artist"], duration: 200)
        _ = try await store.lyrics(for: longTrack)
        let offline = StubHTTP { _ in throw URLError(.notConnectedToInternet) }
        let relaunched = try await makeStore(offline, clock: Clock()).lyrics(for: longTrack)
        XCTAssertTrue(relaunched.isSynced)
    }

    func testNonLatinLocalFileKeys() async throws {
        let id = "local:宇多田ヒカル:First Love"
        let store = makeStore(syncedNow(), clock: Clock())
        let t = makeTrack(id: id, title: "Song", artists: ["Artist"], duration: 200)
        _ = try await store.lyrics(for: t)
        let count = await store.cachedCount()
        XCTAssertEqual(count, 1)
    }
}
