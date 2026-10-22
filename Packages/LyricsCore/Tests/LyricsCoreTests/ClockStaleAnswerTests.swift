import XCTest
@testable import LyricsCore

/// Spotify sometimes answers from a cache for remote devices: the position is a second or
/// two OLD (not identical to the last one, so it is not a "cached repeat"), and the next
/// answer is right again. The lyrics must not jump back and forth for that.
final class ClockStaleAnswerTests: XCTestCase {
    func steadyClock() -> (PlaybackClock, Double) {
        var clock = PlaybackClock(position: 100, at: 1000, isPlaying: true, duration: 300, uncertainty: 0.15)
        var t = 1000.0
        for _ in 0..<10 {
            t += 1.5
            clock.update(position: 100 + (t - 1000), at: t, isPlaying: true, duration: 300, uncertainty: 0.15)
        }
        return (clock, t)
    }

    func testOneStaleAnswerDoesNotRewindTheClock() {
        var (clock, t) = steadyClock()
        t += 1.5
        // This answer is 1.8 s old: it reports where the music was 1.8 s ago.
        clock.update(position: 100 + (t - 1000) - 1.8, at: t, isPlaying: true, duration: 300, uncertainty: 0.15)
        let shown = clock.position(at: t)
        XCTAssertEqual(shown, 100 + (t - 1000), accuracy: 0.5, "a single stale answer moved the clock back by \(100 + (t - 1000) - shown) s")
        // The next answer is right, and the clock is right.
        t += 1.5
        clock.update(position: 100 + (t - 1000), at: t, isPlaying: true, duration: 300, uncertainty: 0.15)
        XCTAssertEqual(clock.position(at: t), 100 + (t - 1000), accuracy: 0.1)
    }

    func testRealBackwardSeekIsStillFollowedWithinTwoPolls() {
        var (clock, t) = steadyClock()
        // The user jumps back 20 s; the answers keep agreeing with the new position.
        var seen = false
        for poll in 1...2 {
            t += 1.5
            clock.update(position: 80 + 1.5 * Double(poll), at: t, isPlaying: true, duration: 300, uncertainty: 0.15)
            if abs(clock.position(at: t) - (80 + 1.5 * Double(poll))) < 0.3 { seen = true }
        }
        XCTAssertTrue(seen, "a real backward seek must be followed within two polls")
    }

    /// "Previous" mid-song restarts it: shown at once, not a poll later (EC37).
    func testRestartFromMidSongIsImmediate() {
        var (clock, t) = steadyClock()
        t += 1.5
        XCTAssertTrue(clock.update(position: 0.4, at: t, isPlaying: true, duration: 300, uncertainty: 0.15))
        XCTAssertEqual(clock.position(at: t), 0.4, accuracy: 0.01)
    }

    func testAJumpBackAsksAgainSoon() {
        var engine = NowPlayingEngine(isSignedIn: true)
        let track = NowPlayingTrack(id: "a", title: "A", artists: ["X"], album: "", duration: 300)
        var t = 1000.0
        for i in 0..<5 {
            _ = engine.apply(PlaybackSample(track: track, position: 100 + Double(i) * 1.5, isPlaying: true), at: t, uncertainty: 0.1)
            t += 1.5
        }
        _ = engine.apply(PlaybackSample(track: track, position: 60, isPlaying: true), at: t, uncertainty: 0.1)
        XCTAssertNotNil(engine.clock?.pendingRewind)
        XCTAssertEqual(engine.nextPollDelay(at: t), NowPlayingEngine.rewindConfirmDelay, accuracy: 0.001)
    }

    /// In the intro a stale answer can land near 0:00 too; that one waits for a second answer.
    func testStaleAnswerInTheIntroIsHeld() {
        var clock = PlaybackClock(position: 6, at: 100, isPlaying: true, duration: 300, uncertainty: 0.05)
        XCTAssertFalse(clock.update(position: 4.2, at: 101.5, isPlaying: true, duration: 300, uncertainty: 0.05))
        XCTAssertEqual(clock.position(at: 101.5), 7.5, accuracy: 0.01)
    }
}
