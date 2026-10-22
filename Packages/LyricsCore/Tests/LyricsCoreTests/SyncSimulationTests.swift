import XCTest
@testable import LyricsCore

/// Plays a scripted session against a simulated Spotify and checks how close
/// the shown lyrics stay to the music, using the real engine and its own poll
/// scheduling. Deterministic (seeded), so it guards sync accuracy from regressing.
final class SyncSimulationTests: XCTestCase {
    /// What really plays, as a function of time.
    struct Truth {
        enum Event { case seek(TimeInterval), pause, resume, skip(NowPlayingTrack), deviceOffline, deviceBack }
        var track: NowPlayingTrack
        var position: TimeInterval = 0
        var isPlaying = true
        /// Spotify keeps saying "playing" but the device stopped (it went offline).
        var offline = false

        mutating func advance(_ dt: TimeInterval) {
            if isPlaying && !offline { position = min(position + dt, track.duration) }
        }

        mutating func apply(_ event: Event) {
            switch event {
            case .seek(let to): position = to
            case .pause: isPlaying = false
            case .resume: isPlaying = true
            case .skip(let next): track = next; position = 0
            case .deviceOffline: offline = true
            case .deviceBack: offline = false
            }
        }
    }

    /// A small seeded random generator so every run is the same.
    struct SeededRandom {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func uniform(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + next() * (range.upperBound - range.lowerBound)
        }
    }

    struct Result {
        var steadyErrors: [Double] = []
        var backwardMoves: [(time: Double, from: Int, to: Int)] = []
        var detection: [String: Double] = [:]
    }

    let step = 0.01
    let maxRTT = 0.8
    /// The longest a change can take to show: a request already in flight when it happened
    /// (it measured too early), then one poll interval, then that request's round trip.
    var detectionLimit: Double { maxRTT + NowPlayingEngine.playingPollInterval + maxRTT + 0.1 }

    /// Lines of varied length (1.5 to 6 s), like real songs.
    func makeLines(seed: UInt64, duration: TimeInterval) -> LyricsTimeline {
        var random = SeededRandom(state: seed)
        var lines: [LyricLine] = []
        var time = 4.0
        while time < duration - 2 {
            lines.append(LyricLine(time: time, text: "line \(lines.count)"))
            time += random.uniform(1.5...6)
        }
        return LyricsTimeline(lines: lines)
    }

    func run(seed: UInt64, script: [(at: Double, event: Truth.Event)], until end: Double,
             cachedRepeatChance: Double = 0.1) -> Result {
        let first = makeTrack(id: "s1", duration: 200)
        let timeline = makeLines(seed: seed, duration: 200)
        var random = SeededRandom(state: seed &+ 99)
        var truth = Truth(track: first)
        var engine = NowPlayingEngine(isSignedIn: true)
        var result = Result()

        var script = script
        var now = 0.0
        var nextPollAt = 0.0
        var inFlight: (start: Double, end: Double, sample: PlaybackSample)?
        var lastReported: PlaybackSample?
        var lastWasCached = false
        var lastEventAt = -100.0
        var pendingDetections: [(name: String, since: Double, check: (NowPlayingEngine, Truth) -> Bool)] = []
        var shownLine: Int?
        var allowBackwardUntil = -1.0

        while now < end {
            // Scripted events.
            while let next = script.first, next.at <= now {
                script.removeFirst()
                truth.apply(next.event)
                lastEventAt = now
                switch next.event {
                case .seek(let to):
                    // Jumping back is the point of a backward seek.
                    if to < truth.position + 1 { allowBackwardUntil = now + detectionLimit }
                    // Shown once the clock re-anchored there, within that request's precision.
                    let precision = maxRTT / 2 + 0.05
                    pendingDetections.append(("seek@\(Int(now))", now, { engine, truth in
                        abs((engine.position(at: now) ?? -9) - truth.position) < precision }))
                case .pause:
                    // The clock ran on until the pause was seen; it then goes back to where the music stopped.
                    allowBackwardUntil = now + detectionLimit
                    pendingDetections.append(("pause@\(Int(now))", now, { engine, _ in !engine.snapshot.isPlaying }))
                case .resume:
                    pendingDetections.append(("resume@\(Int(now))", now, { engine, _ in engine.snapshot.isPlaying }))
                case .skip(let track):
                    pendingDetections.append(("skip@\(Int(now))", now, { engine, _ in engine.snapshot.track?.id == track.id }))
                case .deviceOffline:
                    // Like a pause: the first frozen answer is the truth, and the clock goes back to it once.
                    allowBackwardUntil = now + detectionLimit
                case .deviceBack:
                    // A stall is held at the clock's estimate; Spotify's real position then wins (pinned elsewhere).
                    allowBackwardUntil = now + detectionLimit
                    pendingDetections.append(("deviceBack@\(Int(now))", now, { engine, _ in engine.snapshot.isPlaying }))
                }
            }

            // A request finishing.
            if let request = inFlight, request.end <= now {
                inFlight = nil
                let effects = engine.apply(request.sample, at: (request.start + request.end) / 2,
                                           uncertainty: (request.end - request.start) / 2)
                for case .loadLyrics(let track) in effects {
                    engine.lyricsLoaded(.synced(timeline), for: track.id, at: now)
                }
                lastReported = request.sample
                nextPollAt = now + engine.nextPollDelay(at: now)
            }
            // A request starting: Spotify reads the position at a random moment during it.
            if inFlight == nil, now >= nextPollAt || engine.takeEarlyPoll(at: now) {
                let rtt = random.uniform(0.04...maxRTT)
                let measureAt = random.uniform(0...rtt)
                var future = truth
                // Peek at the truth at the measuring moment (no events are that close in the scripts).
                future.advance(measureAt)
                var sample = PlaybackSample(track: future.track, position: (future.position * 1000).rounded() / 1000,
                                            isPlaying: future.isPlaying)
                // Spotify sometimes answers from a short-lived cache: the previous answer again. Its
                // lifetime is under a poll interval, so it never repeats twice in a row.
                if let last = lastReported, !lastWasCached, last.track?.id == sample.track?.id,
                   random.next() < cachedRepeatChance {
                    sample = last
                    lastWasCached = true
                } else {
                    lastWasCached = false
                }
                inFlight = (now, now + rtt, sample)
            }

            truth.advance(step)
            now += step
            engine.tick(at: now)

            // Measure.
            if let line = engine.snapshot.currentLine, let previous = shownLine, line < previous, now > allowBackwardUntil {
                result.backwardMoves.append((now, previous, line))
            }
            shownLine = engine.snapshot.currentLine ?? shownLine
            if engine.snapshot.track?.id != truth.track.id { shownLine = nil }

            if truth.isPlaying, !truth.offline, now - lastEventAt > 5, engine.snapshot.track?.id == truth.track.id,
               let estimate = engine.position(at: now) {
                result.steadyErrors.append(abs(estimate - truth.position))
            }
            pendingDetections.removeAll { pending in
                guard pending.check(engine, truth) else { return false }
                result.detection[pending.name] = now - pending.since
                return true
            }
        }
        for pending in pendingDetections { result.detection[pending.name] = .infinity }
        return result
    }

    func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    func testStaysInSyncThroughSeeksPausesSkipsAndAStalledDevice() {
        let second = makeTrack(id: "s2", title: "Second", duration: 200)
        let script: [(at: Double, event: Truth.Event)] = [
            (40, .seek(100)), (70, .pause), (80, .resume), (95, .seek(20)),
            (120, .skip(second)), (150, .deviceOffline), (165, .deviceBack), (185, .seek(150)),
        ]
        // Several seeds, so the result isn't luck.
        var errors: [Double] = []
        for seed in UInt64(1)...6 {
            let result = run(seed: seed, script: script, until: 230, cachedRepeatChance: 0)
            errors += result.steadyErrors
            XCTAssertTrue(result.backwardMoves.isEmpty, "seed \(seed): line moved backwards \(result.backwardMoves)")
            for (name, delay) in result.detection {
                XCTAssertLessThanOrEqual(delay, detectionLimit, "seed \(seed): \(name) took \(delay) s to show")
            }
        }
        let p95 = percentile(errors, 0.95)
        let maxError = errors.max() ?? 0
        let median = percentile(errors, 0.5)
        print(String(format: "sync simulation: median %.0f ms, p95 %.0f ms, max %.0f ms over %d samples",
                     median * 1000, p95 * 1000, maxError * 1000, errors.count))
        XCTAssertLessThan(p95, 0.1, "p95 error")
        XCTAssertLessThan(maxError, 0.25, "max error")
    }

    /// A cached answer right after a change hides it for one more poll.
    func testChangesStillShowWithCachedAnswers() {
        let second = makeTrack(id: "s2", title: "Second", duration: 200)
        let script: [(at: Double, event: Truth.Event)] = [(40, .seek(100)), (70, .pause), (80, .resume), (120, .skip(second))]
        for seed in UInt64(1)...6 {
            let result = run(seed: seed, script: script, until: 160, cachedRepeatChance: 0.3)
            XCTAssertTrue(result.backwardMoves.isEmpty, "seed \(seed): \(result.backwardMoves)")
            XCTAssertLessThan(percentile(result.steadyErrors, 0.95), 0.1)
            for (name, delay) in result.detection {
                XCTAssertLessThanOrEqual(delay, detectionLimit + NowPlayingEngine.playingPollInterval + maxRTT,
                                         "seed \(seed): \(name) took \(delay) s")
            }
        }
    }

    func testCachedRepeatsNeverFreezeNormalPlayback() {
        // Half of the answers that can be cached are.
        let result = run(seed: 42, script: [], until: 120, cachedRepeatChance: 0.5)
        XCTAssertTrue(result.backwardMoves.isEmpty)
        XCTAssertLessThan(percentile(result.steadyErrors, 0.95), 0.1)
    }
}
