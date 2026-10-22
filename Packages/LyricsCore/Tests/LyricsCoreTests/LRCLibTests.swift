import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LyricsCore

final class TitleNormalizerTests: XCTestCase {
    func testSimplify() {
        let cases: [(String, String)] = [
            ("Come Together - Remastered 2009", "Come Together"),
            ("Stay (with Justin Bieber)", "Stay"),
            ("Señorita (feat. Someone)", "Señorita"),
            ("Song ft. Other", "Song ft. Other"),
            ("Song [Live]", "Song"),
            ("Song (Radio Edit)", "Song"),
            ("Song (2019 Remaster)", "Song"),
            ("Song (Taylor's Version)", "Song"),
            ("Plain Title", "Plain Title"),
            ("(I Can't Get No) Satisfaction", "(I Can't Get No) Satisfaction"),
            ("- Dash First", "- Dash First"),
            ("   ", "   "),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TitleNormalizer.simplify(input), expected, input)
        }
    }

    func testComparable() {
        XCTAssertEqual(TitleNormalizer.comparable("Beyoncé’s Song!"), "beyoncessong")
        XCTAssertEqual(TitleNormalizer.comparable("ROCK & ROLL"), "rockroll")
        XCTAssertEqual(TitleNormalizer.comparable("夜に駆ける"), "夜に駆ける")
    }
}

final class LRCLibMatchingTests: XCTestCase {
    let track = makeTrack(title: "Get Lucky (feat. Pharrell Williams) - Radio Edit",
                          artists: ["Daft Punk", "Pharrell Williams"], album: "Get Lucky", duration: 248)

    func testBestMatchPrefersSyncedAndCloseDuration() {
        let records = [
            LRCLibRecord(id: 1, trackName: "Get Lucky", artistName: "Daft Punk", duration: 248, plainLyrics: "plain"),
            LRCLibRecord(id: 2, trackName: "Get Lucky", artistName: "Daft Punk feat. Pharrell Williams", duration: 249, syncedLyrics: "[00:01.00]x"),
            LRCLibRecord(id: 3, trackName: "Get Lucky", artistName: "Daft Punk", duration: 369, syncedLyrics: "[00:01.00]x"),
            LRCLibRecord(id: 4, trackName: "Something Else", artistName: "Daft Punk", duration: 248, syncedLyrics: "[00:01.00]x"),
        ]
        XCTAssertEqual(LRCLibClient.bestMatch(in: records, for: track)?.id, 2)
    }

    func testBestMatchRejectsWrongArtistAndEmptyFields() {
        XCTAssertNil(LRCLibClient.bestMatch(in: [LRCLibRecord(id: 1, trackName: "Get Lucky", artistName: "Someone Else", duration: 248, syncedLyrics: "[00:01.00]x")], for: track))
        XCTAssertNil(LRCLibClient.bestMatch(in: [LRCLibRecord(id: 1, trackName: "Get Lucky", artistName: "", duration: 248, syncedLyrics: "[00:01.00]x")], for: track))
        XCTAssertNil(LRCLibClient.bestMatch(in: [LRCLibRecord(id: 1, trackName: nil, artistName: "Daft Punk", syncedLyrics: "[00:01.00]x")], for: track))
        XCTAssertNil(LRCLibClient.bestMatch(in: [], for: track))
    }

    func testCloserDurationWinsBetweenSyncedRecords() {
        let records = [
            LRCLibRecord(id: 1, trackName: "Get Lucky", artistName: "Daft Punk", duration: 252, syncedLyrics: "[00:01.00]x"),
            LRCLibRecord(id: 2, trackName: "Get Lucky", artistName: "Daft Punk", duration: 248.4, syncedLyrics: "[00:01.00]x"),
        ]
        XCTAssertEqual(LRCLibClient.bestMatch(in: records, for: track)?.id, 2)
    }

    func testRankedPutsMatchesFirstThenTheRest() {
        let records = [
            LRCLibRecord(id: 1, trackName: "Unrelated", artistName: "X"),
            LRCLibRecord(id: 2, trackName: "Get Lucky", artistName: "Daft Punk", duration: 248, plainLyrics: "p"),
            LRCLibRecord(id: 3, trackName: "Get Lucky", artistName: "Daft Punk", duration: 248, syncedLyrics: "[00:01.00]x"),
            LRCLibRecord(id: 4, trackName: "Also Unrelated", artistName: "Y"),
        ]
        XCTAssertEqual(LRCLibClient.ranked(records, for: track).map(\.id), [3, 2, 1, 4])
    }

    func testLyricsFromRecord() {
        XCTAssertEqual(Lyrics(record: nil), .notFound)
        XCTAssertEqual(Lyrics(record: LRCLibRecord(id: 1, instrumental: true)), .instrumental)
        XCTAssertEqual(Lyrics(record: LRCLibRecord(id: 1)), .notFound)
        XCTAssertEqual(Lyrics(record: LRCLibRecord(id: 1, plainLyrics: "a\nb")), .plain(["a", "b"]))
        XCTAssertEqual(Lyrics(record: LRCLibRecord(id: 1, plainLyrics: "a", syncedLyrics: "garbage only")), .plain(["a"]))
        guard case .synced(let timeline) = Lyrics(record: LRCLibRecord(id: 1, plainLyrics: "a", syncedLyrics: "[00:01.00]a")) else {
            return XCTFail("expected synced lyrics")
        }
        XCTAssertEqual(timeline.lines, [LyricLine(time: 1, text: "a")])
    }

    func testDecodesLRCLibJSON() throws {
        let body = """
        {"id":3396226,"trackName":"I Want to Live","artistName":"Borislav Slavov","albumName":"Baldur's Gate 3",
         "duration":233,"instrumental":false,"plainLyrics":"I feel your breath","syncedLyrics":"[00:17.12] I feel your breath"}
        """
        let record = try JSONDecoder().decode(LRCLibRecord.self, from: json(body))
        XCTAssertEqual(record.id, 3396226)
        XCTAssertTrue(record.hasSyncedLyrics)
        XCTAssertEqual(try JSONDecoder().decode(LRCLibRecord.self, from: json(#"{"id":1,"syncedLyrics":null}"#)).hasSyncedLyrics, false)
    }
}

final class LRCLibClientTests: XCTestCase {
    let track = makeTrack(id: "sp1", title: "Come Together - Remastered 2009", artists: ["The Beatles"], album: "Abbey Road", duration: 259)
    let synced = #"{"id":10,"trackName":"Come Together","artistName":"The Beatles","duration":259,"syncedLyrics":"[00:01.00]Here come old flat top"}"#
    let plain = #"{"id":11,"trackName":"Come Together","artistName":"The Beatles","duration":259,"plainLyrics":"Here come old flat top"}"#

    func client(_ http: StubHTTP) -> LRCLibClient {
        LRCLibClient(userAgent: "Tests/1.0", http: http)
    }

    func testExactMatchUsesAllSignatureFields() async throws {
        let http = StubHTTP { [synced] _ in (200, json(synced), [:]) }
        let record = try await client(http).lyrics(for: track)
        XCTAssertEqual(record?.id, 10)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.path, "/api/get")
        XCTAssertEqual(request.query, ["track_name": "Come Together - Remastered 2009", "artist_name": "The Beatles",
                                       "album_name": "Abbey Road", "duration": "259"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Tests/1.0")
        XCTAssertEqual(http.requests.count, 1)
    }

    func testFallsBackToSimplifiedTitleThenSearch() async throws {
        let http = StubHTTP { [synced] request in
            switch request.path {
            case "/api/get": return (404, json(#"{"code":404}"#), [:])
            case "/api/search": return (200, json("[\(synced)]"), [:])
            default: return (500, Data(), [:])
            }
        }
        let record = try await client(http).lyrics(for: track)
        XCTAssertEqual(record?.id, 10)
        XCTAssertEqual(http.requests.map(\.path), ["/api/get", "/api/get", "/api/search"])
        XCTAssertEqual(http.requests[1].query["track_name"], "Come Together")
        XCTAssertEqual(http.requests[2].query["track_name"], "Come Together")
    }

    func testServerErrorOnFirstStepDoesNotAbortTheChain() async throws {
        let http = StubHTTP { [synced] request in
            request.path == "/api/search" ? (200, json("[\(synced)]"), [:]) : (500, Data(), [:])
        }
        let record = try await client(http).lyrics(for: track)
        XCTAssertEqual(record?.id, 10)
    }

    func testPlainLyricsFromFirstHitAreKeptWhenNothingSyncedExists() async throws {
        let http = StubHTTP { [plain] request in
            request.path == "/api/search" ? (200, json("[]"), [:]) : (200, json(plain), [:])
        }
        let record = try await client(http).lyrics(for: track)
        XCTAssertEqual(record?.id, 11)
    }

    func testSyncedSearchResultBeatsPlainExactHit() async throws {
        let http = StubHTTP { [plain, synced] request in
            request.path == "/api/search" ? (200, json("[\(synced)]"), [:]) : (200, json(plain), [:])
        }
        let record = try await client(http).lyrics(for: track)
        XCTAssertEqual(record?.id, 10)
    }

    func testExactHitWithWrongDurationIsIgnored() async throws {
        let wrongCut = #"{"id":12,"trackName":"Come Together","artistName":"The Beatles","duration":300,"syncedLyrics":"[00:01.00]x"}"#
        let http = StubHTTP { request in
            request.path == "/api/search" ? (200, json("[]"), [:]) : (200, json(wrongCut), [:])
        }
        let record = try await client(http).lyrics(for: track)
        XCTAssertNil(record)
    }

    func testNothingFoundReturnsNil() async throws {
        let http = StubHTTP { request in
            request.path == "/api/search" ? (200, json("[]"), [:]) : (404, Data(), [:])
        }
        let record = try await client(http).lyrics(for: track)
        XCTAssertNil(record)
    }

    func testEveryStepFailingThrows() async {
        let http = StubHTTP { _ in (503, Data(), [:]) }
        await assertThrows(LRCLibError.http(503)) { _ = try await self.client(http).lyrics(for: self.track) }
    }

    func testCandidatesFallBackToFreeTextSearch() async throws {
        let http = StubHTTP { [synced] request in
            request.query["q"] != nil ? (200, json("[\(synced)]"), [:]) : (200, json("[]"), [:])
        }
        let results = try await client(http).candidates(for: track)
        XCTAssertEqual(results.map(\.id), [10])
        XCTAssertEqual(http.requests.last?.query["q"], "Come Together The Beatles")
    }

    func testGetByID() async throws {
        let http = StubHTTP { [synced] request in
            request.path == "/api/get/10" ? (200, json(synced), [:]) : (404, Data(), [:])
        }
        let found = try await client(http).get(id: 10)
        let missing = try await client(http).get(id: 99)
        XCTAssertEqual(found?.id, 10)
        XCTAssertNil(missing)
    }
}
