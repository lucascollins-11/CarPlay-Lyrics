import Foundation
import LyricsCore
import XCTest
@testable import CarPlayLyrics

/// A clock the test moves by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000
    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
    func advance(_ seconds: TimeInterval) { now += seconds }
}

/// A PlaybackSource whose answers the test sets.
final class FakePlayback: PlaybackSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _next: Result<PlaybackSample, Error> = .success(.nothing)
    private var _upcoming: [NowPlayingTrack] = []
    private var _seeks: [TimeInterval] = []
    private var _seekError: Error?
    private var _polls = 0

    var next: Result<PlaybackSample, Error> {
        get { lock.lock(); defer { lock.unlock() }; return _next }
        set { lock.lock(); _next = newValue; lock.unlock() }
    }
    var upcoming: [NowPlayingTrack] {
        get { lock.lock(); defer { lock.unlock() }; return _upcoming }
        set { lock.lock(); _upcoming = newValue; lock.unlock() }
    }
    var seekError: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _seekError }
        set { lock.lock(); _seekError = newValue; lock.unlock() }
    }
    var seeks: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _seeks }
    var polls: Int { lock.lock(); defer { lock.unlock() }; return _polls }

    func play(_ track: NowPlayingTrack, at position: TimeInterval, playing: Bool = true) {
        next = .success(PlaybackSample(track: track, position: position, isPlaying: playing))
    }

    func currentlyPlaying() async throws -> PlaybackSample {
        let result: Result<PlaybackSample, Error> = locked { _polls += 1; return _next }
        return try result.get()
    }

    func upcomingTracks() async throws -> [NowPlayingTrack] { upcoming }

    func seek(to position: TimeInterval) async throws {
        let error: Error? = locked { _seeks.append(position); return _seekError }
        if let error { throw error }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

/// A LyricsProvider that serves canned lyrics and records requests.
final class FakeLyrics: LyricsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _lyrics: [String: Lyrics] = [:]
    private var _requested: [String] = []
    private var _fail = false

    func set(_ lyrics: Lyrics, for id: String) { lock.lock(); _lyrics[id] = lyrics; lock.unlock() }
    var fail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fail }
        set { lock.lock(); _fail = newValue; lock.unlock() }
    }
    var requested: [String] { lock.lock(); defer { lock.unlock() }; return _requested }

    func lyrics(for track: NowPlayingTrack) async throws -> Lyrics {
        let (result, fail) = lock.withLock {
            _requested.append(track.id)
            return (_lyrics[track.id] ?? .notFound, _fail)
        }
        if fail { throw URLError(.notConnectedToInternet) }
        return result
    }

    func candidates(for track: NowPlayingTrack) async throws -> [LRCLibRecord] {
        [LRCLibRecord(id: 1, trackName: track.title, artistName: track.primaryArtist, plainLyrics: "picked")]
    }

    func choose(_ record: LRCLibRecord, for track: NowPlayingTrack) async throws -> Lyrics {
        Lyrics(record: record)
    }

    func resetChoice(for track: NowPlayingTrack) async throws -> Lyrics {
        try await lyrics(for: track)
    }
}

/// An HTTPClient answering from a closure.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
    private let handler: Handler
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

    init(_ handler: @escaping Handler) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _count += 1 }
        let (status, data) = try await handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

func makeTrack(_ id: String, duration: TimeInterval = 60) -> NowPlayingTrack {
    NowPlayingTrack(id: id, title: "Song \(id)", artists: ["Artist"], album: "Album", duration: duration)
}

func makeTimeline() -> LyricsTimeline {
    LyricsTimeline(lines: (0..<10).map { LyricLine(time: TimeInterval($0 * 5 + 2), text: "line \($0)") })
}

func freshDefaults(_ name: String = #function) -> UserDefaults {
    let suite = "CarPlayLyricsTests.\(name).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

extension XCTestCase {
    /// Waits (on the main actor) until `condition` is true or the timeout passes.
    @MainActor
    func waitUntil(timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
