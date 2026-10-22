import Foundation

/// A built-in song that "plays" without Spotify, so the app can be tried
/// (and UI tested) before any accounts are set up. Lyrics are original.
public enum DemoSong {
    public static let track = NowPlayingTrack(
        id: "demo-open-road",
        title: "Open Road (Demo)",
        artists: ["CarPlay Lyrics"],
        album: "Demo",
        duration: 96
    )

    public static let lrc = """
    [ti:Open Road (Demo)]
    [ar:CarPlay Lyrics]
    [00:03.00]Engine humming, morning light
    [00:07.00]Coffee in the cupholder, the city out of sight
    [00:12.00]Every mile marker counting down
    [00:16.00]Leaving all the noise of town
    [00:21.00]
    [00:24.00]Roll the windows, let it in
    [00:28.00]Every song is where the story should begin
    [00:33.00]Read the words and sing along
    [00:37.00]On the open road where we belong
    [00:42.00]
    [00:45.00]Green lights all the way down Main
    [00:49.00]Sunshine breaking through the last of the rain
    [00:54.00]Turn it up and hold the line
    [00:58.00]Every word arriving right on time
    [01:03.00]
    [01:06.00]Roll the windows, let it in
    [01:10.00]Every song is where the story should begin
    [01:15.00]Read the words and sing along
    [01:19.00]On the open road where we belong
    [01:24.00]On the open road where we belong
    [01:30.00]
    """

    public static var timeline: LyricsTimeline { LyricsTimeline(lrc: lrc) }
}

/// Plays `DemoSong` on a loop against a monotonic clock.
public final class DemoPlayback: PlaybackSource, @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var startedAt: TimeInterval
    private var pausedAt: TimeInterval?

    public init(now: @escaping @Sendable () -> TimeInterval = MonotonicClock.now) {
        self.now = now
        self.startedAt = now()
    }

    public var position: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return positionLocked()
    }

    public var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return pausedAt == nil
    }

    public func currentlyPlaying() async throws -> PlaybackSample {
        locked { PlaybackSample(track: DemoSong.track, position: positionLocked(), isPlaying: pausedAt == nil) }
    }

    public func upcomingTracks() async throws -> [NowPlayingTrack] { [] }

    public func seek(to position: TimeInterval) async throws {
        locked {
            let clamped = min(max(0, position), DemoSong.track.duration)
            let reference = pausedAt ?? now()
            startedAt = reference - clamped
        }
    }

    public func setPlaying(_ playing: Bool) {
        lock.lock(); defer { lock.unlock() }
        if playing, let pausedAt {
            startedAt += now() - pausedAt
            self.pausedAt = nil
        } else if !playing, pausedAt == nil {
            pausedAt = now()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func positionLocked() -> TimeInterval {
        let reference = pausedAt ?? now()
        let elapsed = max(0, reference - startedAt)
        return elapsed.truncatingRemainder(dividingBy: DemoSong.track.duration)
    }
}

/// Serves the demo song's lyrics without touching the network.
public struct DemoLyricsProvider: LyricsProvider {
    public init() {}

    public func lyrics(for track: NowPlayingTrack) async throws -> Lyrics {
        track.id == DemoSong.track.id ? .synced(DemoSong.timeline) : .notFound
    }

    public func candidates(for track: NowPlayingTrack) async throws -> [LRCLibRecord] {
        [LRCLibRecord(id: 0, trackName: DemoSong.track.title, artistName: DemoSong.track.primaryArtist,
                      albumName: DemoSong.track.album, duration: DemoSong.track.duration, instrumental: false,
                      plainLyrics: nil, syncedLyrics: DemoSong.lrc)]
    }

    public func choose(_ record: LRCLibRecord, for track: NowPlayingTrack) async throws -> Lyrics {
        Lyrics(record: record)
    }

    public func resetChoice(for track: NowPlayingTrack) async throws -> Lyrics {
        try await lyrics(for: track)
    }
}
