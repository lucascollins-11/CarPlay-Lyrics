import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LyricsCore

final class NowPlayingEngineTests: XCTestCase {
    let track = makeTrack(id: "t1", duration: 60)
    let other = makeTrack(id: "t2", title: "Other", duration: 60)

    func playing(_ track: NowPlayingTrack?, at position: TimeInterval, playing: Bool = true) -> PlaybackSample {
        PlaybackSample(track: track, position: position, isPlaying: playing)
    }

    func loadedEngine(at position: TimeInterval = 0, time: TimeInterval = 100) -> NowPlayingEngine {
        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(playing(track, at: position), at: time)
        engine.lyricsLoaded(.synced(makeTimeline()), for: track.id, at: time)
        return engine
    }

    func testNewTrackStartsLyricsLoadAndPrefetch() {
        var engine = NowPlayingEngine(isSignedIn: true)
        let effects = engine.apply(playing(track, at: 0), at: 100)
        XCTAssertEqual(effects, [.loadLyrics(track), .prefetchUpcoming])
        XCTAssertEqual(engine.snapshot.track, track)
        XCTAssertEqual(engine.snapshot.lyrics, .loading)
        XCTAssertTrue(engine.snapshot.isPlaying)
    }

    func testSameTrackDoesNotReloadLyrics() {
        var engine = loadedEngine()
        XCTAssertEqual(engine.apply(playing(track, at: 3), at: 103), [])
        guard case .loaded = engine.snapshot.lyrics else { return XCTFail("lyrics should stay loaded") }
    }

    func testFollowsLinesAsTimePasses() {
        var engine = loadedEngine()
        XCTAssertNil(engine.snapshot.currentLine)
        XCTAssertTrue(engine.tick(at: 102))
        XCTAssertEqual(engine.snapshot.currentLine, 0)
        XCTAssertFalse(engine.tick(at: 103), "no change within a line")
        engine.tick(at: 107.5)
        XCTAssertEqual(engine.snapshot.currentLine, 1)
        engine.tick(at: 200)
        XCTAssertEqual(engine.snapshot.currentLine, 9)
    }

    func testPauseFreezesTheLine() {
        var engine = loadedEngine()
        _ = engine.apply(playing(track, at: 8, playing: false), at: 108)
        XCTAssertFalse(engine.snapshot.isPlaying)
        XCTAssertEqual(engine.snapshot.currentLine, 1)
        engine.tick(at: 500)
        XCTAssertEqual(engine.snapshot.currentLine, 1)
    }

    func testSeekDetectedFromSample() {
        var engine = loadedEngine()
        _ = engine.apply(playing(track, at: 30), at: 101)
        XCTAssertEqual(engine.snapshot.currentLine, 5)
    }

    func testRepeatOneRestartsTheSameTrack() {
        var engine = loadedEngine()
        engine.tick(at: 158)
        XCTAssertEqual(engine.snapshot.currentLine, 9)
        _ = engine.apply(playing(track, at: 0.3), at: 160.5)
        XCTAssertNil(engine.snapshot.currentLine)
        guard case .loaded = engine.snapshot.lyrics else { return XCTFail("lyrics kept on repeat") }
    }

    func testTrackChangeResetsLineAndLoadsNewLyrics() {
        var engine = loadedEngine()
        engine.tick(at: 110)
        let effects = engine.apply(playing(other, at: 0.5), at: 120)
        XCTAssertEqual(effects, [.loadLyrics(other), .prefetchUpcoming])
        XCTAssertNil(engine.snapshot.currentLine)
        XCTAssertEqual(engine.snapshot.lyrics, .loading)
    }

    func testLateLyricsForAPreviousTrackAreIgnored() {
        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(playing(track, at: 0), at: 100)
        _ = engine.apply(playing(other, at: 0), at: 103)
        engine.lyricsLoaded(.synced(makeTimeline()), for: track.id, at: 104)
        XCTAssertEqual(engine.snapshot.lyrics, .loading)
        engine.lyricsFailed("nope", for: track.id, at: 104)
        XCTAssertEqual(engine.snapshot.lyrics, .loading)
    }

    func testNothingPlayingClearsEverything() {
        var engine = loadedEngine()
        XCTAssertEqual(engine.apply(.nothing, at: 105), [.cancelLyrics])
        XCTAssertNil(engine.snapshot.track)
        XCTAssertEqual(engine.snapshot.lyrics, .none)
        XCTAssertNil(engine.position(at: 106))
        XCTAssertEqual(engine.apply(.nothing, at: 110), [], "no repeated cancel")
    }

    /// Spotify answers "nothing" for a moment around skips and device hand-offs.
    func testOneEmptyAnswerDoesNotBlankTheLyrics() {
        var engine = loadedEngine()
        XCTAssertEqual(engine.apply(.nothing, at: 101.5), [], "kept for now")
        XCTAssertEqual(engine.snapshot.track, track)
        XCTAssertNotNil(engine.position(at: 102))
        XCTAssertEqual(engine.nextPollDelay(at: 101.5), NowPlayingEngine.fastPollInterval, "looks again soon")
        // The same song comes back: not treated as a new one.
        XCTAssertEqual(engine.apply(playing(track, at: 2.5), at: 102.5), [])
        guard case .loaded = engine.snapshot.lyrics else { return XCTFail("lyrics kept") }
    }

    func testTwoEmptyAnswersInARowClearTheSong() {
        var engine = loadedEngine()
        XCTAssertEqual(engine.apply(.nothing, at: 101), [])
        XCTAssertEqual(engine.apply(.nothing, at: 102), [.cancelLyrics])
        XCTAssertNil(engine.snapshot.track)
    }

    func testLongRateLimitIsShown() {
        var engine = loadedEngine()
        XCTAssertEqual(engine.pollFailed(SpotifyAPIError.rateLimited(retryAfter: 10), at: 101), 10)
        XCTAssertNil(engine.snapshot.problem, "a short wait isn't worth mentioning")
        XCTAssertTrue(engine.isRateLimited(at: 102))
        XCTAssertEqual(engine.pollFailed(SpotifyAPIError.rateLimited(retryAfter: 600), at: 103), 600, "Retry-After is honoured")
        XCTAssertEqual(engine.snapshot.problem, "Spotify asked this app to wait 10 min. Song changes will show after that.")
        XCTAssertTrue(engine.isRateLimited(at: 650))
        XCTAssertFalse(engine.isRateLimited(at: 800))
        engine.tick(at: 108)
        XCTAssertEqual(engine.snapshot.currentLine, 1, "the current song keeps going")
    }

    func testUnexpectedAnswerHasItsOwnMessage() {
        var engine = loadedEngine()
        let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        XCTAssertEqual(engine.pollFailed(error, at: 101), 2)
        XCTAssertEqual(engine.snapshot.problem, NowPlayingEngine.unexpectedAnswerMessage)
    }

    func testNetworkRestoredResetsTheBackoff() {
        var engine = loadedEngine()
        for _ in 0..<6 { _ = engine.pollFailed(URLError(.notConnectedToInternet), at: 101) }
        XCTAssertEqual(engine.pollFailed(URLError(.notConnectedToInternet), at: 101), 30)
        engine.networkRestored(at: 102)
        XCTAssertEqual(engine.pollFailed(URLError(.timedOut), at: 103), 2, "starts again from a short wait")
    }

    func testFailedLyricsAreRetriedAfterInterval() {
        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(playing(track, at: 0), at: 100)
        engine.lyricsFailed("offline", for: track.id, at: 101)
        XCTAssertEqual(engine.snapshot.lyrics, .failed("offline"))
        XCTAssertEqual(engine.apply(playing(track, at: 10), at: 110), [])
        XCTAssertEqual(engine.apply(playing(track, at: 21), at: 121), [.loadLyrics(track)])
        XCTAssertEqual(engine.snapshot.lyrics, .loading)
    }

    func testOffsetsShiftTheLine() {
        var engine = loadedEngine()
        engine.tick(at: 106.8)
        XCTAssertEqual(engine.snapshot.currentLine, 0)
        engine.globalOffset = 0.5
        engine.tick(at: 106.8)
        XCTAssertEqual(engine.snapshot.currentLine, 1, "positive offset shows lyrics earlier")
        engine.adjustTrackOffset(by: -1, at: 106.8)
        XCTAssertEqual(engine.effectiveOffset, -0.5, accuracy: 0.0001)
        XCTAssertEqual(engine.snapshot.currentLine, 0)
    }

    func testTrackOffsetIsRememberedPerSong() {
        var engine = loadedEngine()
        XCTAssertEqual(engine.adjustTrackOffset(by: 0.25, at: 100), 0.25)
        XCTAssertEqual(engine.adjustTrackOffset(by: 0.25, at: 100), 0.5)
        XCTAssertEqual(engine.trackOffsets, ["t1": 0.5])
        _ = engine.apply(playing(other, at: 0), at: 101)
        XCTAssertEqual(engine.snapshot.trackOffset, 0)
        _ = engine.apply(playing(track, at: 0), at: 102)
        XCTAssertEqual(engine.snapshot.trackOffset, 0.5)
        engine.resetTrackOffset(at: 103)
        XCTAssertEqual(engine.trackOffsets, [:])
    }

    func testOffsetRoundingAvoidsFloatingPointDrift() {
        var engine = loadedEngine()
        for _ in 0..<10 { engine.adjustTrackOffset(by: 0.1, at: 100) }
        XCTAssertEqual(engine.snapshot.trackOffset, 1.0)
        var empty = NowPlayingEngine()
        XCTAssertEqual(empty.adjustTrackOffset(by: 1, at: 0), 0, "no track, no offset")
    }

    func testSeekPositionLandsOnTheLine() {
        var engine = loadedEngine()
        engine.globalOffset = 0.4
        let target = try! XCTUnwrap(engine.seekPosition(forLine: 3))
        engine.seekLocally(to: target, at: 200)
        XCTAssertEqual(engine.snapshot.currentLine, 3)
        XCTAssertEqual(engine.playbackPosition(at: 200) ?? -1, target, accuracy: 0.0001)
        XCTAssertNil(engine.seekPosition(forLine: 99))
    }

    func testPollFailureHandling() {
        var engine = loadedEngine()
        XCTAssertEqual(engine.pollFailed(CancellationError(), at: 101), 0)
        XCTAssertEqual(engine.pollFailed(URLError(.cancelled), at: 101), 0)
        XCTAssertNil(engine.snapshot.problem, "cancellation is not a problem")

        XCTAssertEqual(engine.pollFailed(SpotifyAPIError.rateLimited(retryAfter: 1), at: 101), 3)
        XCTAssertEqual(engine.pollFailed(SpotifyAPIError.rateLimited(retryAfter: 40), at: 101), 40)

        XCTAssertEqual(engine.pollFailed(SpotifyAPIError.forbidden, at: 101), 30)
        XCTAssertEqual(engine.snapshot.problem, SpotifyAPIError.forbidden.errorDescription)

        XCTAssertEqual(engine.pollFailed(URLError(.notConnectedToInternet), at: 102), 2)
        XCTAssertEqual(engine.snapshot.problem, NowPlayingEngine.unreachableMessage)
        XCTAssertEqual(engine.pollFailed(URLError(.timedOut), at: 104), 4)
        XCTAssertEqual(engine.pollFailed(URLError(.timedOut), at: 108), 8)
        for _ in 0..<10 { _ = engine.pollFailed(URLError(.timedOut), at: 110) }
        XCTAssertEqual(engine.pollFailed(URLError(.timedOut), at: 140), 30, "backoff is capped")

        // Lyrics keep following the song through the outage.
        engine.tick(at: 108)
        XCTAssertEqual(engine.snapshot.currentLine, 1)

        _ = engine.apply(playing(track, at: 41), at: 141)
        XCTAssertNil(engine.snapshot.problem, "a good poll clears the problem")
        XCTAssertEqual(engine.pollFailed(URLError(.timedOut), at: 142), 2, "backoff resets")
    }

    func testAuthFailuresWaitForTheSignInLayer() {
        var engine = loadedEngine()
        XCTAssertEqual(engine.pollFailed(SpotifyAuthError.notSignedIn, at: 101), 10)
        XCTAssertEqual(engine.pollFailed(SpotifyAuthError.tokenRejected("x"), at: 101), 10)
        XCTAssertEqual(engine.pollFailed(SpotifyAPIError.unauthorized, at: 101), 10)
        XCTAssertNil(engine.snapshot.problem)
    }

    func testPollDelays() {
        var engine = NowPlayingEngine(isSignedIn: true)
        XCTAssertEqual(engine.nextPollDelay(at: 0), 6, "idle")

        _ = engine.apply(playing(track, at: 10), at: 100)
        XCTAssertEqual(engine.nextPollDelay(at: 100), NowPlayingEngine.fastPollInterval, "just changed")
        XCTAssertEqual(engine.nextPollDelay(at: 106), NowPlayingEngine.playingPollInterval, "steady")

        _ = engine.apply(playing(track, at: 16, playing: false), at: 106)
        XCTAssertEqual(engine.nextPollDelay(at: 106), NowPlayingEngine.fastPollInterval, "pause just happened")
        XCTAssertEqual(engine.nextPollDelay(at: 112), 5, "paused")

        _ = engine.apply(playing(track, at: 58.5), at: 120)
        XCTAssertEqual(engine.nextPollDelay(at: 121), 0.9, accuracy: 0.001, "song about to end")
        XCTAssertEqual(engine.nextPollDelay(at: 121.4), 0.75, "never faster than 0.75 s")
        XCTAssertEqual(engine.nextPollDelay(at: 126), NowPlayingEngine.playingPollInterval,
                       "sitting at the end: back to normal, early polls are capped separately")

        engine.noteUserAction(at: 200)
        _ = engine.apply(.nothing, at: 200)
        XCTAssertEqual(engine.nextPollDelay(at: 201), 2)
    }

    func testRateLimitSlowsSteadyPolling() {
        var engine = loadedEngine(at: 10, time: 100)
        XCTAssertEqual(engine.nextPollDelay(at: 110), NowPlayingEngine.playingPollInterval)
        XCTAssertEqual(engine.pollFailed(SpotifyAPIError.rateLimited(retryAfter: 4), at: 110), 4)
        _ = engine.apply(playing(track, at: 24.2), at: 114.2)
        XCTAssertEqual(engine.nextPollDelay(at: 120), NowPlayingEngine.rateLimitedPollInterval, "eases off after a 429")
        XCTAssertEqual(engine.nextPollDelay(at: 110 + NowPlayingEngine.rateLimitCooldown + 1), 1.5, accuracy: 2,
                       "back to normal later (or the end-of-song shortcut)")
    }

    func testEarlyPollsWhenTheSongShouldHaveEndedAreCapped() {
        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(playing(track, at: 59), at: 100)
        XCTAssertFalse(engine.takeEarlyPoll(at: 100.5))
        XCTAssertFalse(engine.takeEarlyPoll(at: 101.2), "sample too recent")
        var taken = 0
        for step in 0..<20 where engine.takeEarlyPoll(at: 102 + Double(step)) { taken += 1 }
        XCTAssertEqual(taken, NowPlayingEngine.maxEarlyPolls)
        _ = engine.apply(playing(other, at: 0), at: 130)
        XCTAssertFalse(engine.takeEarlyPoll(at: 131), "new song")
    }

    /// The playing device went offline: Spotify keeps saying "playing" with the same position.
    func testFrozenPositionHoldsTheLineAndSlowsPolling() {
        var engine = loadedEngine(at: 10, time: 100)
        XCTAssertEqual(engine.snapshot.currentLine, 1)
        var lines: [Int?] = [engine.snapshot.currentLine]
        var delays: [TimeInterval] = []
        // Repeats for 12 s: longer than the grace period for a weak-signal hiccup.
        for step in 1...4 {
            let time = 100 + Double(step) * 3
            _ = engine.apply(playing(track, at: 10), at: time)
            engine.tick(at: time + 0.5)
            lines.append(engine.snapshot.currentLine)
            delays.append(engine.nextPollDelay(at: time + 0.5))
        }
        XCTAssertEqual(lines[3], 3, "kept running through the grace period")
        XCTAssertTrue(engine.isStalled)
        XCTAssertFalse(engine.snapshot.isPlaying, "shown as paused")
        XCTAssertEqual(lines.compactMap { $0 }, lines.compactMap { $0 }.sorted(), "the line never moves backwards")
        XCTAssertEqual(lines.last, 4, "held where the clock had got to (22 s)")
        XCTAssertEqual(delays.last ?? 0, NowPlayingEngine.playingPollInterval, "steady pace, no endless fast polling")
        engine.tick(at: 200)
        XCTAssertEqual(engine.snapshot.currentLine, 4, "frozen while stalled")

        // Playback really moves again (the device is back).
        _ = engine.apply(playing(track, at: 30), at: 120)
        XCTAssertFalse(engine.isStalled)
        XCTAssertTrue(engine.snapshot.isPlaying)
        XCTAssertEqual(engine.snapshot.currentLine, 5)
        XCTAssertEqual(engine.nextPollDelay(at: 120), NowPlayingEngine.fastPollInterval)
    }

    /// Spotify can return the same cached progress for requests about a second apart.
    func testOneCachedRepeatIsNotAStall() {
        var engine = loadedEngine(at: 10, time: 100)
        _ = engine.apply(playing(track, at: 10), at: 101.25)
        XCTAssertFalse(engine.isStalled)
        XCTAssertTrue(engine.snapshot.isPlaying, "the Dashboard must not flip to Paused")
        XCTAssertEqual(engine.position(at: 101.25) ?? 0, 11.25, accuracy: 0.001, "the clock keeps running, no jump back")
        XCTAssertEqual(engine.nextPollDelay(at: 101.25), NowPlayingEngine.fastPollInterval)
        // The next answer is fresh again.
        _ = engine.apply(playing(track, at: 12.5), at: 102.5)
        XCTAssertFalse(engine.isStalled)
        XCTAssertEqual(engine.position(at: 102.5) ?? 0, 12.5, accuracy: 0.001)
    }

    /// Weak signal: Spotify's server state stops for a few seconds while the phone plays buffered audio.
    func testShortServerHiccupKeepsTheLyricsRunning() {
        var engine = loadedEngine(at: 10, time: 100)
        for time in [101.5, 103.0, 104.5, 106.0, 107.5] {
            _ = engine.apply(playing(track, at: 10), at: time)
            XCTAssertTrue(engine.snapshot.isPlaying, "never Paused because of a short hiccup")
        }
        XCTAssertFalse(engine.isStalled)
        XCTAssertEqual(engine.position(at: 107.5) ?? 0, 17.5, accuracy: 0.001, "kept interpolating")
        // The server catches up: agrees with the clock, no jump.
        _ = engine.apply(playing(track, at: 19), at: 109)
        XCTAssertEqual(engine.position(at: 109) ?? 0, 19, accuracy: 0.01)
    }

    func testTwoQuickRepeatsAreNotAStallEither() {
        var engine = loadedEngine(at: 10, time: 100)
        _ = engine.apply(playing(track, at: 10), at: 101)
        _ = engine.apply(playing(track, at: 10), at: 102)
        XCTAssertFalse(engine.isStalled, "two repeats within 2.5 s")
        XCTAssertTrue(engine.snapshot.isPlaying)
    }

    /// Pinned on purpose: when a stall ends, Spotify's real position wins even if it is behind the held line.
    func testRecoveringFromAStallFollowsTheRealPositionEvenBackwards() {
        var engine = loadedEngine(at: 10, time: 100)
        _ = engine.apply(playing(track, at: 10), at: 103)
        _ = engine.apply(playing(track, at: 10), at: 106)
        XCTAssertFalse(engine.isStalled, "within the grace period")
        _ = engine.apply(playing(track, at: 10), at: 111)
        XCTAssertTrue(engine.isStalled)
        XCTAssertEqual(engine.snapshot.currentLine, 3, "held at the estimate of 21 s")
        _ = engine.apply(playing(track, at: 10.5), at: 130)
        XCTAssertFalse(engine.isStalled)
        XCTAssertEqual(engine.snapshot.currentLine, 1, "jumps back once to where the device really is")
        XCTAssertEqual(engine.playbackPosition(at: 130) ?? 0, 10.5, accuracy: 0.001)
    }

    func testOrdinaryPlaybackIsNotAStall() {
        var engine = loadedEngine(at: 10, time: 100)
        for step in 1...5 {
            _ = engine.apply(playing(track, at: 10 + Double(step) * 3), at: 100 + Double(step) * 3)
        }
        XCTAssertFalse(engine.isStalled)
        XCTAssertTrue(engine.snapshot.isPlaying)
        // Two quick polls in a row can report the same position without it being a stall.
        _ = engine.apply(playing(track, at: 25.3), at: 115.3)
        XCTAssertFalse(engine.isStalled)
    }

    func testRepeatedUnauthorizedAsksForSignIn() {
        var engine = loadedEngine()
        for _ in 1..<NowPlayingEngine.maxUnauthorized {
            _ = engine.pollFailed(SpotifyAPIError.unauthorized, at: 101)
        }
        XCTAssertFalse(engine.needsSignIn)
        _ = engine.apply(playing(track, at: 2), at: 102)
        _ = engine.pollFailed(SpotifyAPIError.unauthorized, at: 103)
        XCTAssertFalse(engine.needsSignIn, "a good poll resets the count")
        for _ in 1..<NowPlayingEngine.maxUnauthorized {
            _ = engine.pollFailed(SpotifyAPIError.unauthorized, at: 104)
        }
        XCTAssertTrue(engine.needsSignIn)
        engine.setSignedIn(false)
        XCTAssertFalse(engine.needsSignIn)
    }

    func testTickSleepsUntilTheNextLine() {
        var engine = loadedEngine(at: 0, time: 100)
        XCTAssertEqual(engine.nextTickDelay(at: 100), 1, "first line is 2 s away: capped at 1 s")
        XCTAssertEqual(engine.nextTickDelay(at: 101.5), 0.51, accuracy: 0.001, "wakes just after line 0 starts")
        engine.tick(at: 101.5)
        XCTAssertEqual(engine.nextTickDelay(at: 102.0), 1)
        XCTAssertEqual(engine.nextTickDelay(at: 106.99), 0.02, accuracy: 0.001, "never a busy loop")
        _ = engine.apply(playing(track, at: 10, playing: false), at: 110)
        XCTAssertEqual(engine.nextTickDelay(at: 110), 1, "paused: nothing will change")
    }

    func testSignOutResets() {
        var engine = loadedEngine()
        engine.setSignedIn(false)
        XCTAssertEqual(engine.snapshot, NowPlayingSnapshot(isSignedIn: false))
        engine.setSignedIn(true)
        XCTAssertTrue(engine.snapshot.isSignedIn)
    }

    func testPlainLyricsHaveNoCurrentLine() {
        var engine = NowPlayingEngine(isSignedIn: true)
        _ = engine.apply(playing(track, at: 10), at: 100)
        engine.lyricsLoaded(.plain(["a", "b"]), for: track.id, chosenByUser: true, at: 100)
        XCTAssertFalse(engine.tick(at: 130))
        XCTAssertNil(engine.snapshot.currentLine)
        XCTAssertTrue(engine.snapshot.lyricsChosenByUser)
    }
}

final class DemoPlaybackTests: XCTestCase {
    final class FakeClock: @unchecked Sendable {
        var now: TimeInterval = 1000
    }

    func testPlaysPausesSeeksAndLoops() async throws {
        let clock = FakeClock()
        let demo = DemoPlayback(now: { clock.now })
        var sample = try await demo.currentlyPlaying()
        XCTAssertEqual(sample.track, DemoSong.track)
        XCTAssertEqual(sample.position, 0, accuracy: 0.001)
        XCTAssertTrue(sample.isPlaying)

        clock.now += 10
        XCTAssertEqual(demo.position, 10, accuracy: 0.001)

        demo.setPlaying(false)
        clock.now += 50
        sample = try await demo.currentlyPlaying()
        XCTAssertFalse(sample.isPlaying)
        XCTAssertEqual(sample.position, 10, accuracy: 0.001)

        demo.setPlaying(true)
        clock.now += 5
        XCTAssertEqual(demo.position, 15, accuracy: 0.001)

        try await demo.seek(to: 90)
        XCTAssertEqual(demo.position, 90, accuracy: 0.001)
        clock.now += 10
        XCTAssertEqual(demo.position, 100 - DemoSong.track.duration, accuracy: 0.001, "loops back to the start")
    }

    func testDemoLyricsAreSyncedAndFitTheSong() async throws {
        let timeline = DemoSong.timeline
        XCTAssertGreaterThan(timeline.lines.count, 15)
        XCTAssertLessThan(timeline.lines.last?.time ?? .infinity, DemoSong.track.duration)
        let lyrics = try await DemoLyricsProvider().lyrics(for: DemoSong.track)
        XCTAssertEqual(lyrics, .synced(timeline))
        let other = try await DemoLyricsProvider().lyrics(for: makeTrack())
        XCTAssertEqual(other, .notFound)
    }
}
