import XCTest
@testable import LyricsCore

final class LRCParserTests: XCTestCase {
    func testParsesCommonTimestampFormats() {
        let lines = LRCParser.parse("""
        [ar:Daft Punk]
        [ti:Get Lucky]
        [00:01.5]one
        [00:02.25]two
        [00:03.125]three
        [00:04]four
        [01:05:50]five
        """)
        XCTAssertEqual(lines.map(\.text), ["one", "two", "three", "four", "five"])
        XCTAssertEqual(lines[0].time, 1.5, accuracy: 0.0001)
        XCTAssertEqual(lines[1].time, 2.25, accuracy: 0.0001)
        XCTAssertEqual(lines[2].time, 3.125, accuracy: 0.0001)
        XCTAssertEqual(lines[3].time, 4, accuracy: 0.0001)
        XCTAssertEqual(lines[4].time, 65.5, accuracy: 0.0001)
    }

    func testRepeatedTimestampsAreExpandedAndSorted() {
        let lines = LRCParser.parse("""
        [00:10.00][00:30.00]Chorus
        [00:20.00]Verse
        """)
        XCTAssertEqual(lines, [
            LyricLine(time: 10, text: "Chorus"),
            LyricLine(time: 20, text: "Verse"),
            LyricLine(time: 30, text: "Chorus"),
        ])
    }

    func testOffsetTagShiftsLinesEarlier() {
        let lines = LRCParser.parse("""
        [offset:+500]
        [00:10.00]Hello
        """)
        XCTAssertEqual(lines.first?.time ?? 0, 9.5, accuracy: 0.0001)
    }

    func testEmptyLinesBecomeGapsAndWordTagsAreStripped() {
        let lines = LRCParser.parse("""
        [00:01.00]<00:01.00>Word <00:01.50>by <00:02.00>word
        [00:05.00]
        """)
        XCTAssertEqual(lines[0].text, "Word by word")
        XCTAssertTrue(lines[1].isGap)
    }

    func testIgnoresGarbage() {
        XCTAssertEqual(LRCParser.parse("no tags here\n[xx:yy]bad\n[length: 03:20]"), [])
    }
}

final class LyricsTimelineTests: XCTestCase {
    let timeline = LyricsTimeline(lines: (0..<10).map { LyricLine(time: TimeInterval($0 * 5 + 2), text: "line \($0)") })

    func testIndexLookup() {
        XCTAssertNil(timeline.index(at: 0))
        XCTAssertNil(timeline.index(at: 1.99))
        XCTAssertEqual(timeline.index(at: 2), 0)
        XCTAssertEqual(timeline.index(at: 6.9), 0)
        XCTAssertEqual(timeline.index(at: 7), 1)
        XCTAssertEqual(timeline.index(at: 1000), 9)
    }

    func testTimeUntilNextLine() {
        XCTAssertEqual(timeline.timeUntilNextLine(after: 0) ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(timeline.timeUntilNextLine(after: 3) ?? -1, 4, accuracy: 0.0001)
        XCTAssertNil(timeline.timeUntilNextLine(after: 100))
    }

    func testWindow() {
        XCTAssertEqual(timeline.window(around: nil, before: 1, count: 4).range, 0..<4)
        XCTAssertEqual(timeline.window(around: 0, before: 1, count: 4).range, 0..<4)
        XCTAssertEqual(timeline.window(around: 5, before: 1, count: 4).range, 4..<8)
        XCTAssertEqual(timeline.window(around: 9, before: 1, count: 4).range, 6..<10)
        XCTAssertEqual(LyricsTimeline(lines: []).window(around: nil, before: 1, count: 4).range, 0..<0)
    }
}

final class PlaybackClockTests: XCTestCase {
    func testRunsForwardWhilePlayingAndStopsWhenPaused() {
        var clock = PlaybackClock(position: 10, at: 100, isPlaying: true, duration: 200)
        XCTAssertEqual(clock.position(at: 102.5), 12.5, accuracy: 0.0001)
        clock.update(position: 20, at: 110, isPlaying: false)
        XCTAssertEqual(clock.position(at: 150), 20, accuracy: 0.0001)
    }

    func testIgnoresJitterButFollowsSeeks() {
        var clock = PlaybackClock(position: 10, at: 100, isPlaying: true)
        XCTAssertFalse(clock.update(position: 13.2, at: 103, isPlaying: true))
        XCTAssertEqual(clock.position(at: 103), 13, accuracy: 0.0001)
        XCTAssertTrue(clock.update(position: 60, at: 104, isPlaying: true))
        XCTAssertEqual(clock.position(at: 105), 61, accuracy: 0.0001)
    }

    func testClampsToDurationAndReportsEnd() {
        let clock = PlaybackClock(position: 195, at: 0, isPlaying: true, duration: 200)
        XCTAssertFalse(clock.hasReachedEnd(at: 4))
        XCTAssertTrue(clock.hasReachedEnd(at: 6))
        XCTAssertEqual(clock.position(at: 10), 200, accuracy: 0.0001)
    }
}

final class SpotifyDecodingTests: XCTestCase {
    func testDecodesTrack() throws {
        let json = """
        {"timestamp":1700000000000,"progress_ms":42500,"is_playing":true,"currently_playing_type":"track",
         "item":{"id":"abc","name":"Get Lucky (feat. Pharrell Williams)","duration_ms":248413,
          "artists":[{"name":"Daft Punk"},{"name":"Pharrell Williams"}],
          "album":{"name":"Random Access Memories","images":[{"url":"https://i.scdn.co/small","width":64,"height":64},{"url":"https://i.scdn.co/big","width":640,"height":640}]}}}
        """
        let sample = try PlaybackSample.decode(Data(json.utf8))
        XCTAssertTrue(sample.isPlaying)
        XCTAssertEqual(sample.position, 42.5, accuracy: 0.0001)
        XCTAssertEqual(sample.track?.id, "abc")
        XCTAssertEqual(sample.track?.artists, ["Daft Punk", "Pharrell Williams"])
        XCTAssertEqual(sample.track?.duration ?? 0, 248.413, accuracy: 0.0001)
        XCTAssertEqual(sample.track?.artworkURL?.absoluteString, "https://i.scdn.co/big")
    }

    func testPodcastHasNoTrack() throws {
        let json = #"{"progress_ms":1000,"is_playing":true,"currently_playing_type":"episode","item":null}"#
        let sample = try PlaybackSample.decode(Data(json.utf8))
        XCTAssertNil(sample.track)
    }
}

final class LRCLibTests: XCTestCase {
    let track = NowPlayingTrack(id: "1", title: "Get Lucky (feat. Pharrell Williams) - Radio Edit",
                                artists: ["Daft Punk", "Pharrell Williams"], album: "Get Lucky", duration: 248)

    func testSimplifyTitle() {
        XCTAssertEqual(TitleNormalizer.simplify("Come Together - Remastered 2009"), "Come Together")
        XCTAssertEqual(TitleNormalizer.simplify("Stay (with Justin Bieber)"), "Stay")
        XCTAssertEqual(TitleNormalizer.simplify("Song [Live]"), "Song")
        XCTAssertEqual(TitleNormalizer.simplify("Plain Title"), "Plain Title")
        XCTAssertEqual(TitleNormalizer.comparable("Beyoncé’s Song!"), "beyoncessong")
    }

    func testBestMatchPrefersSyncedAndCloseDuration() {
        let records = [
            LRCLibRecord(id: 1, trackName: "Get Lucky", artistName: "Daft Punk", duration: 248, plainLyrics: "plain"),
            LRCLibRecord(id: 2, trackName: "Get Lucky", artistName: "Daft Punk feat. Pharrell Williams", duration: 249, syncedLyrics: "[00:01.00]x"),
            LRCLibRecord(id: 3, trackName: "Get Lucky", artistName: "Daft Punk", duration: 369, syncedLyrics: "[00:01.00]x"),
            LRCLibRecord(id: 4, trackName: "Something Else", artistName: "Daft Punk", duration: 248, syncedLyrics: "[00:01.00]x"),
        ]
        XCTAssertEqual(LRCLibClient.bestMatch(in: records, for: track)?.id, 2)
    }

    func testBestMatchRejectsWrongArtist() {
        let records = [LRCLibRecord(id: 1, trackName: "Get Lucky", artistName: "Someone Else", duration: 248, syncedLyrics: "[00:01.00]x")]
        XCTAssertNil(LRCLibClient.bestMatch(in: records, for: track))
    }

    func testLyricsFromRecord() {
        XCTAssertEqual(Lyrics(record: nil), .notFound)
        XCTAssertEqual(Lyrics(record: LRCLibRecord(id: 1, instrumental: true)), .instrumental)
        XCTAssertEqual(Lyrics(record: LRCLibRecord(id: 1, plainLyrics: "a\nb")), .plain(["a", "b"]))
        guard case .synced(let timeline) = Lyrics(record: LRCLibRecord(id: 1, plainLyrics: "a", syncedLyrics: "[00:01.00]a")) else {
            return XCTFail("expected synced lyrics")
        }
        XCTAssertEqual(timeline.lines, [LyricLine(time: 1, text: "a")])
    }

    func testDecodesLRCLibJSON() throws {
        let json = """
        {"id":3396226,"trackName":"I Want to Live","artistName":"Borislav Slavov","albumName":"Baldur's Gate 3",
         "duration":233,"instrumental":false,"plainLyrics":"I feel your breath","syncedLyrics":"[00:17.12] I feel your breath"}
        """
        let record = try JSONDecoder().decode(LRCLibRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.id, 3396226)
        XCTAssertTrue(record.hasSyncedLyrics)
    }
}
