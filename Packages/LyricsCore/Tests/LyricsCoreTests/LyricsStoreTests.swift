import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LyricsCore

final class LyricsStoreTests: XCTestCase {
    let track = makeTrack(id: "abc123", title: "Song", artists: ["Artist"], duration: 200)
    let synced = #"{"id":7,"trackName":"Song","artistName":"Artist","duration":200,"syncedLyrics":"[00:01.00]hello"}"#
    var directory: URL!

    override func setUp() {
        directory = temporaryDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeStore(_ http: StubHTTP) -> LyricsStore {
        LyricsStore(client: LRCLibClient(http: http), directory: directory)
    }

    func testCachesInMemoryAndOnDisk() async throws {
        let http = StubHTTP { [synced] _ in (200, json(synced), [:]) }
        let store = makeStore(http)
        let first = try await store.lyrics(for: track)
        let second = try await store.lyrics(for: track)
        XCTAssertEqual(first, second)
        XCTAssertEqual(http.requests.count, 1)
        let cached = await store.cachedCount()
        XCTAssertEqual(cached, 1)

        // A new store (an app relaunch) reads the disk cache without the network.
        let offline = StubHTTP { _ in throw URLError(.notConnectedToInternet) }
        let relaunched = makeStore(offline)
        let fromDisk = try await relaunched.lyrics(for: track)
        XCTAssertEqual(fromDisk, first)
        XCTAssertEqual(offline.requests.count, 0)
    }

    func testMissesAreNotWrittenToDisk() async throws {
        let http = StubHTTP { request in request.path == "/api/search" ? (200, json("[]"), [:]) : (404, Data(), [:]) }
        let store = makeStore(http)
        let lyrics = try await store.lyrics(for: track)
        XCTAssertEqual(lyrics, .notFound)
        let cached = await store.cachedCount()
        XCTAssertEqual(cached, 0)
    }

    func testConcurrentRequestsForOneTrackShareOneLookup() async throws {
        let http = StubHTTP { [synced] _ in
            Thread.sleep(forTimeInterval: 0.05)
            return (200, json(synced), [:])
        }
        let store = makeStore(http)
        async let a = store.lyrics(for: track)
        async let b = store.lyrics(for: track)
        async let c = store.lyrics(for: track)
        let results = try await [a, b, c]
        XCTAssertEqual(Set(results.map { "\($0)" }).count, 1)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testChoosingAnotherVersionOverridesCacheAndCanBeReset() async throws {
        let http = StubHTTP { [synced] _ in (200, json(synced), [:]) }
        let store = makeStore(http)
        _ = try await store.lyrics(for: track)

        let pick = LRCLibRecord(id: 99, trackName: "Song", artistName: "Artist", duration: 200, plainLyrics: "picked by hand")
        let chosen = try await store.choose(pick, for: track)
        XCTAssertEqual(chosen, .plain(["picked by hand"]))
        let isChosen = await store.isChosenByUser(track)
        XCTAssertTrue(isChosen)

        // The pick survives a relaunch.
        let relaunched = makeStore(StubHTTP { _ in (500, Data(), [:]) })
        let afterRelaunch = try await relaunched.lyrics(for: track)
        XCTAssertEqual(afterRelaunch, .plain(["picked by hand"]))

        let reset = try await store.resetChoice(for: track)
        guard case .synced = reset else { return XCTFail("expected the automatic match back") }
        let stillChosen = await store.isChosenByUser(track)
        XCTAssertFalse(stillChosen)
    }

    func testChoosingARecordWithoutLyricsFetchesItByID() async throws {
        let http = StubHTTP { [synced] request in
            request.path == "/api/get/7" ? (200, json(synced), [:]) : (404, Data(), [:])
        }
        let store = makeStore(http)
        let lyrics = try await store.choose(LRCLibRecord(id: 7, trackName: "Song"), for: track)
        guard case .synced = lyrics else { return XCTFail("expected synced lyrics") }
    }

    func testReadsFilesWrittenByTheFirstVersion() async throws {
        let legacy = LRCLibRecord(id: 5, trackName: "Song", artistName: "Artist", plainLyrics: "old format")
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent("abc123.json"))
        let store = makeStore(StubHTTP { _ in (500, Data(), [:]) })
        let lyrics = try await store.lyrics(for: track)
        XCTAssertEqual(lyrics, .plain(["old format"]))
    }

    func testUnsafeTrackIDsMakeSafeFileNames() async {
        let store = makeStore(StubHTTP { _ in (500, Data(), [:]) })
        let url = await store.fileURL(trackID: "local:Me/You-../../etc")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        let plain = await store.fileURL(trackID: "4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(plain.lastPathComponent, "4uLU6hMCjMI75M1A2tKUQC.json")
    }

    func testClearRemovesEverything() async throws {
        let http = StubHTTP { [synced] _ in (200, json(synced), [:]) }
        let store = makeStore(http)
        _ = try await store.lyrics(for: track)
        _ = try await store.lyrics(for: makeTrack(id: "other", title: "Song", artists: ["Artist"], duration: 200))
        let removed = await store.clear()
        XCTAssertEqual(removed, 2)
        _ = try await store.lyrics(for: track)
        XCTAssertEqual(http.requests.count, 3, "cleared lyrics are fetched again")
    }

    func testNetworkErrorPropagatesAndIsNotCached() async throws {
        let failing = StubHTTP { _ in throw URLError(.timedOut) }
        let store = makeStore(failing)
        do {
            _ = try await store.lyrics(for: track)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let cached = await store.cachedCount()
        XCTAssertEqual(cached, 0)
    }

    func testSlowLookupDoesNotOverwriteTheUsersPick() async throws {
        let http = StubHTTP { [synced] _ in
            Thread.sleep(forTimeInterval: 0.2)
            return (200, json(synced), [:])
        }
        let store = makeStore(http)
        let track = self.track
        let prefetch = Task { try await store.lyrics(for: track) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let pick = LRCLibRecord(id: 99, trackName: "Song", artistName: "Artist", albumName: nil, duration: 200,
                                instrumental: false, plainLyrics: "picked", syncedLyrics: nil)
        _ = try await store.choose(pick, for: track)
        _ = try await prefetch.value

        let chosen = await store.isChosenByUser(track)
        XCTAssertTrue(chosen, "the finished lookup must not replace the pick")
        let lyrics = try await store.lyrics(for: track)
        XCTAssertEqual(lyrics, .plain(["picked"]))
    }

    func testSlowLookupDoesNotRefillAClearedCache() async throws {
        let http = StubHTTP { [synced] _ in
            Thread.sleep(forTimeInterval: 0.2)
            return (200, json(synced), [:])
        }
        let store = makeStore(http)
        let track = self.track
        let prefetch = Task { try await store.lyrics(for: track) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await store.clear()
        _ = try await prefetch.value
        let cached = await store.cachedCount()
        XCTAssertEqual(cached, 0, "Delete my data stays deleted")
    }
}
