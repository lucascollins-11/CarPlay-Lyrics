import XCTest
@testable import LyricsCore

final class LyricsDisplayTests: XCTestCase {
    let track = makeTrack(id: "t1", title: "Song", artists: ["A", "B"], duration: 60)

    func snapshot(_ lyrics: LyricsState, line: Int? = nil, playing: Bool = true) -> NowPlayingSnapshot {
        NowPlayingSnapshot(isSignedIn: true, track: track, isPlaying: playing, lyrics: lyrics, currentLine: line)
    }

    func testMessagesNeverAskTheDriverToUseTheirPhone() {
        let messages = [
            LyricsDisplay.make(for: NowPlayingSnapshot(isSignedIn: false), maxRows: 6),
            LyricsDisplay.make(for: NowPlayingSnapshot(isSignedIn: true), maxRows: 6),
            LyricsDisplay.make(for: NowPlayingSnapshot(isSignedIn: true, problem: "x"), maxRows: 6),
        ]
        for case let .message(title, subtitle) in messages {
            let text = (title + " " + (subtitle ?? "")).lowercased()
            XCTAssertFalse(text.contains("iphone"), text)
            XCTAssertFalse(text.contains("phone"), text)
            XCTAssertFalse(text.contains("open "), text)
        }
        XCTAssertEqual(messages.count, 3)
        guard case .message(let title, _) = messages[0] else { return XCTFail() }
        XCTAssertEqual(title, "Spotify isn't connected")
        guard case .message(let idle, _) = messages[1] else { return XCTFail() }
        XCTAssertEqual(idle, "Nothing playing")
        guard case .message(let offline, _) = messages[2] else { return XCTFail() }
        XCTAssertEqual(offline, "Can't reach Spotify")
    }

    func testDemoModeWorksSignedOut() {
        let display = LyricsDisplay.make(for: NowPlayingSnapshot(isSignedIn: false, isDemo: true, track: track, lyrics: .loading), maxRows: 6)
        guard case .rows(let header, _) = display else { return XCTFail() }
        XCTAssertEqual(header, "Song · A, B")
    }

    func testStatusRows() {
        func firstRow(_ state: LyricsState) -> String? {
            guard case .rows(_, let rows) = LyricsDisplay.make(for: snapshot(state), maxRows: 6) else { return nil }
            return rows.first?.text
        }
        XCTAssertEqual(firstRow(.loading), "Finding lyrics…")
        XCTAssertEqual(firstRow(.none), "Finding lyrics…")
        XCTAssertEqual(firstRow(.failed("x")), "Lyrics unavailable right now")
        XCTAssertEqual(firstRow(.loaded(.notFound)), "No lyrics for this song")
        XCTAssertEqual(firstRow(.loaded(.instrumental)), LyricsDisplay.instrumentalText)
    }

    func testSyncedWindowMarksCurrentLine() {
        let display = LyricsDisplay.make(for: snapshot(.loaded(.synced(makeTimeline())), line: 4), maxRows: 5, linesBefore: 1)
        guard case .rows(let header, let rows) = display else { return XCTFail() }
        XCTAssertEqual(header, "Song · A, B")
        XCTAssertEqual(rows.map(\.text), ["line 3", "line 4", "line 5", "line 6", "line 7"])
        XCTAssertEqual(rows.map(\.isCurrent), [false, true, false, false, false])
        XCTAssertEqual(rows.map(\.lineIndex), [3, 4, 5, 6, 7])
    }

    func testBeforeFirstLineShowsWaitingMarker() {
        let display = LyricsDisplay.make(for: snapshot(.loaded(.synced(makeTimeline())), line: nil), maxRows: 4)
        guard case .rows(_, let rows) = display else { return XCTFail() }
        XCTAssertEqual(rows.map(\.text), ["♪", "line 0", "line 1", "line 2"])
        XCTAssertEqual(rows.first?.isCurrent, true)
        XCTAssertEqual(rows.count, 4)
    }

    func testRowCountRespectsTheCarLimit() {
        for limit in [1, 3, 12] {
            let display = LyricsDisplay.make(for: snapshot(.loaded(.synced(makeTimeline(count: 40))), line: 20), maxRows: limit)
            guard case .rows(_, let rows) = display else { return XCTFail() }
            XCTAssertEqual(rows.count, limit)
            XCTAssertTrue(rows.contains { $0.isCurrent }, "limit \(limit)")
        }
    }

    func testGapsAndLongLines() {
        let timeline = LyricsTimeline(lines: [
            LyricLine(time: 1, text: ""),
            LyricLine(time: 2, text: "This is a very long lyric line that will not fit on one CarPlay row"),
        ])
        let display = LyricsDisplay.make(for: snapshot(.loaded(.synced(timeline)), line: 0), maxRows: 6, wrapLimit: 30)
        guard case .rows(_, let rows) = display else { return XCTFail() }
        XCTAssertEqual(rows[0].text, "♪")
        XCTAssertEqual(rows[1].text, "This is a very long lyric line")
        XCTAssertEqual(rows[1].detail, "that will not fit on one CarPlay row")
    }

    func testPlainLyricsAreLabelledAndTrimmed() {
        let display = LyricsDisplay.make(for: snapshot(.loaded(.plain(["a", "", "b", "c"]))), maxRows: 2)
        guard case .rows(let header, let rows) = display else { return XCTFail() }
        XCTAssertEqual(header, "Song · A, B · not synced")
        XCTAssertEqual(rows.map(\.text), ["a", "b"])
        XCTAssertFalse(rows.contains { $0.isCurrent })
    }

    func testHeaderWithoutArtist() {
        let noArtist = NowPlayingSnapshot(isSignedIn: true, track: makeTrack(artists: []), lyrics: .loading)
        guard case .rows(let header, _) = LyricsDisplay.make(for: noArtist, maxRows: 6) else { return XCTFail() }
        XCTAssertEqual(header, "Song")
    }
}

final class LiveLyricsContentTests: XCTestCase {
    let track = makeTrack(id: "t1", title: "Song", artists: ["A"], duration: 60)

    func testCurrentAndNextLine() {
        let timeline = LyricsTimeline(lines: [
            LyricLine(time: 1, text: "one"), LyricLine(time: 2, text: ""), LyricLine(time: 3, text: "three"),
        ])
        let snap = NowPlayingSnapshot(isSignedIn: true, track: track, isPlaying: true, lyrics: .loaded(.synced(timeline)), currentLine: 0)
        let content = LiveLyricsContent.make(for: snap, position: 1.5)
        XCTAssertEqual(content.current, "one")
        XCTAssertEqual(content.next, "three", "gaps are skipped for the next line")
        XCTAssertEqual(content.title, "Song")
        XCTAssertEqual(content.position, 1.5)

        var before = snap
        before.currentLine = nil
        XCTAssertEqual(LiveLyricsContent.make(for: before, position: 0).current, "♪")
        XCTAssertEqual(LiveLyricsContent.make(for: before, position: 0).next, "one")

        var last = snap
        last.currentLine = 2
        XCTAssertNil(LiveLyricsContent.make(for: last, position: 3).next)
    }

    func testPausedAndStatusContent() {
        let paused = NowPlayingSnapshot(isSignedIn: true, track: track, isPlaying: false,
                                        lyrics: .loaded(.synced(makeTimeline())), currentLine: 1)
        XCTAssertEqual(LiveLyricsContent.make(for: paused, position: 8).current, "Paused · line 1")
        XCTAssertEqual(LiveLyricsContent.make(for: NowPlayingSnapshot(isSignedIn: true), position: nil), .idle)
        XCTAssertEqual(LiveLyricsContent.make(for: NowPlayingSnapshot(isSignedIn: false), position: nil).current, "Spotify isn't connected")
        let loading = NowPlayingSnapshot(isSignedIn: true, track: track, isPlaying: true, lyrics: .loading)
        XCTAssertEqual(LiveLyricsContent.make(for: loading, position: 0).current, "Finding lyrics…")
    }

    func testSameTextIgnoresPosition() {
        let a = LiveLyricsContent(title: "t", artist: "a", current: "c", next: "n", isPlaying: true, position: 1, duration: 9)
        var b = a
        b.position = 5
        XCTAssertTrue(a.showsSameText(as: b))
        b.current = "d"
        XCTAssertFalse(a.showsSameText(as: b))
    }

    func testCodableRoundTrip() throws {
        let content = LiveLyricsContent(title: "t", artist: "a", current: "c", next: nil, isPlaying: true, position: 1, duration: 9)
        XCTAssertEqual(try JSONDecoder().decode(LiveLyricsContent.self, from: JSONEncoder().encode(content)), content)
    }
}

final class LineSplitterTests: XCTestCase {
    func testSplits() {
        XCTAssertEqual(LineSplitter.split("short", limit: 10).0, "short")
        XCTAssertNil(LineSplitter.split("short", limit: 10).1)
        let (a, b) = LineSplitter.split("one two three four", limit: 9)
        XCTAssertEqual(a, "one two")
        XCTAssertEqual(b, "three four")
        let (word, rest) = LineSplitter.split("Supercalifragilistic yes", limit: 5)
        XCTAssertEqual(word, "Supercalifragilistic", "a long single word stays whole")
        XCTAssertEqual(rest, "yes")
    }

    func testNothingIsLost() {
        let text = "the quick brown fox jumps over the lazy dog again and again"
        for limit in 1...40 {
            let (a, b) = LineSplitter.split(text, limit: limit)
            XCTAssertEqual([a, b].compactMap { $0 }.joined(separator: " "), text)
        }
    }
}
