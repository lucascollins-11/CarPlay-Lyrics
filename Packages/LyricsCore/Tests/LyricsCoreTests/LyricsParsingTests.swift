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

    func testLongSongsPastAnHour() {
        let lines = LRCParser.parse("[75:30.00]late")
        XCTAssertEqual(lines.first?.time ?? 0, 4530, accuracy: 0.0001)
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

    func testOutOfOrderLinesAreSortedStably() {
        let lines = LRCParser.parse("""
        [00:20.00]b
        [00:10.00]a
        [00:20.00]c
        """)
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c"])
    }

    func testOffsetTagShiftsLinesEarlier() {
        let lines = LRCParser.parse("""
        [offset:+500]
        [00:10.00]Hello
        """)
        XCTAssertEqual(lines.first?.time ?? 0, 9.5, accuracy: 0.0001)
    }

    func testNegativeOffsetShiftsLater() {
        let lines = LRCParser.parse("[offset:-250]\n[00:10.00]Hello")
        XCTAssertEqual(lines.first?.time ?? 0, 10.25, accuracy: 0.0001)
    }

    func testOffsetNeverMakesTimesNegative() {
        let lines = LRCParser.parse("[offset:5000]\n[00:01.00]Hello")
        XCTAssertEqual(lines.first?.time, 0)
    }

    func testEmptyLinesBecomeGapsAndWordTagsAreStripped() {
        let lines = LRCParser.parse("""
        [00:01.00]<00:01.00>Word <00:01.50>by <00:02.00>word
        [00:05.00]
        """)
        XCTAssertEqual(lines[0].text, "Word by word")
        XCTAssertTrue(lines[1].isGap)
    }

    func testKeepsAngleBracketsThatAreNotTimeTags() {
        XCTAssertEqual(LRCParser.parse("[00:01.00]I <3 you").first?.text, "I <3 you")
    }

    func testHandlesWindowsLineEndingsAndWhitespace() {
        let lines = LRCParser.parse("[00:01.00] one \r\n  [00:02.00]two\r\n")
        XCTAssertEqual(lines.map(\.text), ["one", "two"])
    }

    func testUnicodeText() {
        XCTAssertEqual(LRCParser.parse("[00:01.00]夜に駆ける ✨").first?.text, "夜に駆ける ✨")
    }

    func testIgnoresGarbage() {
        XCTAssertEqual(LRCParser.parse("no tags here\n[xx:yy]bad\n[length: 03:20]\n[-1:00.00]neg\n[00:1a.00]bad"), [])
        XCTAssertEqual(LRCParser.parse(""), [])
    }

    func testParseTimestamp() {
        XCTAssertEqual(LRCParser.parseTimestamp("00:00"), 0)
        XCTAssertEqual(LRCParser.parseTimestamp("3:07.5"), 187.5)
        XCTAssertNil(LRCParser.parseTimestamp("ar:Someone"))
        XCTAssertNil(LRCParser.parseTimestamp("1:2:3:4"))
        XCTAssertNil(LRCParser.parseTimestamp(""))
    }
}

final class LyricsTimelineTests: XCTestCase {
    let timeline = makeTimeline()

    func testIndexLookup() {
        XCTAssertNil(timeline.index(at: 0))
        XCTAssertNil(timeline.index(at: 1.99))
        XCTAssertEqual(timeline.index(at: 2), 0)
        XCTAssertEqual(timeline.index(at: 6.9), 0)
        XCTAssertEqual(timeline.index(at: 7), 1)
        XCTAssertEqual(timeline.index(at: 1000), 9)
        XCTAssertNil(timeline.index(at: -5))
    }

    func testIndexLookupMatchesLinearScanEverywhere() {
        let lines = LRCParser.parse((0..<200).map { String(format: "[%02d:%05.2f]l%d", $0 / 60, Double($0 % 60) + 0.37, $0) }.joined(separator: "\n"))
        let timeline = LyricsTimeline(lines: lines)
        for step in 0..<2500 {
            let position = Double(step) * 0.1
            let expected = lines.lastIndex { $0.time <= position }
            XCTAssertEqual(timeline.index(at: position), expected, "at \(position)")
        }
    }

    func testEmptyTimeline() {
        let empty = LyricsTimeline(lines: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.index(at: 10))
        XCTAssertNil(empty.timeUntilNextLine(after: 0))
        XCTAssertEqual(empty.window(around: nil, before: 1, count: 4).range, 0..<0)
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
        XCTAssertEqual(timeline.window(around: 5, before: 0, count: 3).range, 5..<8)
        XCTAssertEqual(timeline.window(around: 2, before: 1, count: 50).range, 0..<10)
        XCTAssertEqual(timeline.window(around: 2, before: 1, count: 0).range, 0..<0)
    }

    func testWindowAlwaysContainsCurrentLine() {
        for count in 1...12 {
            for before in 0...3 {
                for index in 0..<10 {
                    let window = timeline.window(around: index, before: before, count: count)
                    XCTAssertTrue(window.range.contains(index), "count \(count) before \(before) index \(index)")
                    XCTAssertEqual(window.range.count, min(count, 10))
                }
            }
        }
    }
}

final class PlaybackClockTests: XCTestCase {
    func testRunsForwardWhilePlayingAndStopsWhenPaused() {
        var clock = PlaybackClock(position: 10, at: 100, isPlaying: true, duration: 200)
        XCTAssertEqual(clock.position(at: 102.5), 12.5, accuracy: 0.0001)
        clock.update(position: 20, at: 110, isPlaying: false)
        XCTAssertEqual(clock.position(at: 150), 20, accuracy: 0.0001)
    }

    func testResumeReanchors() {
        var clock = PlaybackClock(position: 20, at: 0, isPlaying: false)
        XCTAssertTrue(clock.update(position: 20.1, at: 30, isPlaying: true))
        XCTAssertEqual(clock.position(at: 32), 22.1, accuracy: 0.0001)
    }

    func testIgnoresJitterButFollowsSeeks() {
        var clock = PlaybackClock(position: 10, at: 100, isPlaying: true)
        XCTAssertFalse(clock.update(position: 13.2, at: 103, isPlaying: true))
        let blended = clock.position(at: 103)
        XCTAssertEqual(blended, 13.2, accuracy: 0.02, "no jump, but a precise sample that the clock can't explain wins (\(blended))")
        var imprecise = PlaybackClock(position: 10, at: 100, isPlaying: true)
        XCTAssertFalse(imprecise.update(position: 13.2, at: 103, isPlaying: true, uncertainty: 0.6))
        XCTAssertEqual(imprecise.position(at: 103), 13, accuracy: 0.01, "a slow request barely moves a precise clock")
        XCTAssertFalse(imprecise.update(position: 13.5, at: 103, isPlaying: true, uncertainty: 0.6),
                       "within the round trip's uncertainty: not a seek")
        XCTAssertTrue(clock.update(position: 60, at: 104, isPlaying: true))
        XCTAssertEqual(clock.position(at: 105), 61, accuracy: 0.0001)
        XCTAssertFalse(clock.update(position: 5, at: 106, isPlaying: true), "one answer back could be a stale one")
        XCTAssertEqual(clock.position(at: 106), 62, accuracy: 0.0001)
        XCTAssertTrue(clock.update(position: 6.5, at: 107.5, isPlaying: true), "seeking backwards, once a second answer agrees")
        XCTAssertEqual(clock.position(at: 108), 7, accuracy: 0.0001)
    }

    func testPausedPositionChangesAreFollowed() {
        var clock = PlaybackClock(position: 10, at: 0, isPlaying: false)
        XCTAssertTrue(clock.update(position: 10.1, at: 1, isPlaying: false))
        XCTAssertEqual(clock.position(at: 5), 10.1, accuracy: 0.0001)
    }

    func testClampsToDurationAndReportsEnd() {
        let clock = PlaybackClock(position: 195, at: 0, isPlaying: true, duration: 200)
        XCTAssertFalse(clock.hasReachedEnd(at: 4))
        XCTAssertTrue(clock.hasReachedEnd(at: 6))
        XCTAssertEqual(clock.position(at: 10), 200, accuracy: 0.0001)
        XCTAssertFalse(PlaybackClock(position: 200, at: 0, isPlaying: false, duration: 200).hasReachedEnd(at: 10))
    }

    func testTimeGoingBackwardsDoesNotRewind() {
        let clock = PlaybackClock(position: 10, at: 100, isPlaying: true)
        XCTAssertEqual(clock.position(at: 90), 10, accuracy: 0.0001)
    }
}
