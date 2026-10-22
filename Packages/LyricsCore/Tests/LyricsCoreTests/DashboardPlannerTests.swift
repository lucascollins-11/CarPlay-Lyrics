import XCTest
@testable import LyricsCore

final class DashboardPlannerTests: XCTestCase {
    let track = makeTrack(id: "t1", duration: 60)

    func snapshot(_ timeline: LyricsTimeline = makeTimeline(), playing: Bool = true) -> NowPlayingSnapshot {
        NowPlayingSnapshot(isSignedIn: true, track: track, isPlaying: playing, lyrics: .loaded(.synced(timeline)))
    }

    func testLinesAreSentLeadSecondsEarly() {
        var planner = DashboardPlanner(lead: 0.3)
        // Line 1 starts at 7 s.
        var plan = planner.plan(snapshot: snapshot(), position: 5.5, now: 99)
        XCTAssertEqual(plan.send?.current, "line 0")
        XCTAssertEqual(plan.wakeAfter, 1.21, accuracy: 0.001, "wakes 0.3 s before line 1")
        plan = planner.plan(snapshot: snapshot(), position: 6.71, now: 100.21)
        XCTAssertEqual(plan.send?.current, "line 1", "sent ahead of 7 s so it lands on time")
    }

    func testNothingIsSentWhenTheTextIsTheSame() {
        var planner = DashboardPlanner(lead: 0)
        XCTAssertNotNil(planner.plan(snapshot: snapshot(), position: 3, now: 0).send)
        XCTAssertNil(planner.plan(snapshot: snapshot(), position: 4, now: 1).send)
    }

    func testUpdatesAreThrottledButTheNewestLineWins() {
        let fast = LyricsTimeline(lines: [LyricLine(time: 0, text: "a"), LyricLine(time: 2, text: "b"),
                                          LyricLine(time: 2.2, text: "c"), LyricLine(time: 4, text: "d")])
        var planner = DashboardPlanner(lead: 0)
        _ = planner.plan(snapshot: snapshot(fast), position: 1.9, now: 10)
        let early = planner.plan(snapshot: snapshot(fast), position: 2.05, now: 10.15)
        XCTAssertNil(early.send, "too soon after the last update")
        XCTAssertEqual(early.wakeAfter, 0.25, accuracy: 0.001)
        let later = planner.plan(snapshot: snapshot(fast), position: 2.3, now: 10.4)
        XCTAssertEqual(later.send?.current, "b / c", "the short line is kept with its neighbour, nothing skipped")
    }

    func testShortLinesAreShownWithTheNextLine() {
        let fast = LyricsTimeline(lines: [LyricLine(time: 1, text: "quick"), LyricLine(time: 1.8, text: "words"),
                                          LyricLine(time: 5, text: "slow line"), LyricLine(time: 9, text: "end")])
        var planner = DashboardPlanner(lead: 0)
        XCTAssertEqual(planner.plan(snapshot: snapshot(fast), position: 1.2, now: 0).send?.current, "quick / words")
        XCTAssertNil(planner.plan(snapshot: snapshot(fast), position: 2, now: 1).send, "still the same pair while 'words' plays")
        let slow = planner.plan(snapshot: snapshot(fast), position: 5.1, now: 4)
        XCTAssertEqual(slow.send?.current, "slow line")
        XCTAssertEqual(slow.send?.next, "end")
    }

    func testFirstLineIsNeverOutOfRange() {
        let fast = LyricsTimeline(lines: [LyricLine(time: 1, text: "a"), LyricLine(time: 1.5, text: "b")])
        var planner = DashboardPlanner(lead: 0)
        XCTAssertEqual(planner.plan(snapshot: snapshot(fast), position: 1.1, now: 0).send?.current, "a / b")
        XCTAssertEqual(planner.plan(snapshot: snapshot(fast), position: 0.2, now: 1).send?.current, LyricsDisplay.gapText)
    }

    func testLongPauseShowsNeutralText() {
        var planner = DashboardPlanner(lead: 0.3)
        let paused = snapshot(playing: false)
        let first = planner.plan(snapshot: paused, position: 8, now: 0)
        XCTAssertEqual(first.send?.current, "Paused · line 1", "no lead while paused")
        XCTAssertEqual(first.wakeAfter, DashboardPlanner.longPause, accuracy: 0.02)
        let long = planner.plan(snapshot: paused, position: 8, now: DashboardPlanner.longPause + 0.01)
        XCTAssertEqual(long.send?.current, DashboardPlanner.pausedText)
        XCTAssertNil(long.send?.next)
        XCTAssertEqual(planner.plan(snapshot: snapshot(), position: 8, now: 200).send?.current, "line 1", "playing again")
    }

    func testRefreshesWhilePlayingSoTheActivityIsNotStale() {
        var planner = DashboardPlanner(lead: 0)
        let long = LyricsTimeline(lines: [LyricLine(time: 0, text: "only line")])
        XCTAssertNotNil(planner.plan(snapshot: snapshot(long), position: 1, now: 0).send)
        XCTAssertNil(planner.plan(snapshot: snapshot(long), position: 20, now: 19).send)
        XCTAssertNotNil(planner.plan(snapshot: snapshot(long), position: 31, now: 30).send, "re-sent after 30 s")
    }
}
