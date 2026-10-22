import Foundation

/// Where lyrics come from. LRCLIB plus a cache in the app, canned lyrics in tests.
public protocol LyricsProvider: Sendable {
    func lyrics(for track: NowPlayingTrack) async throws -> Lyrics
    /// Other versions the user can pick from when the automatic match is wrong.
    func candidates(for track: NowPlayingTrack) async throws -> [LRCLibRecord]
    /// Remembers the user's pick for this track and returns its lyrics.
    func choose(_ record: LRCLibRecord, for track: NowPlayingTrack) async throws -> Lyrics
    /// Forgets the user's pick and the cached lyrics for this track.
    func resetChoice(for track: NowPlayingTrack) async throws -> Lyrics
}

/// Looks up lyrics on LRCLIB and caches them by Spotify track ID, in memory
/// and on disk, so a song you replay in the car loads instantly and offline.
public actor LyricsStore: LyricsProvider {
    private let client: LRCLibClient
    private let directory: URL
    private var memory: [String: Lyrics] = [:]
    private var inFlight: [String: Task<Lyrics, Error>] = [:]
    /// Bumped by `choose`, `resetChoice` and `clear`, so a lookup that was already
    /// running doesn't overwrite the user's pick or bring back deleted lyrics.
    private var generations: [String: Int] = [:]
    private var clearCount = 0
    /// Background re-checks of old plain/instrumental entries, by track ID.
    private var refreshes: [String: Task<Void, Never>] = [:]
    private let now: @Sendable () -> Date

    /// Plain and instrumental results are looked up again after this long, because synced
    /// lyrics for new releases are often added to LRCLIB weeks later. User picks are never re-checked.
    public static let recheckInterval: TimeInterval = 14 * 24 * 3600

    public init(client: LRCLibClient, directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.directory = directory
        self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func lyrics(for track: NowPlayingTrack) async throws -> Lyrics {
        if let cached = memory[track.id] {
            return cached
        }
        if let entry = readEntry(trackID: track.id) {
            let lyrics = Lyrics(record: entry.record, trackDuration: track.duration)
            memory[track.id] = lyrics
            if needsRecheck(entry, lyrics: lyrics) {
                // Show what we have now; a better match is picked up from the next play on.
                startRecheck(for: track)
            }
            return lyrics
        }
        // Prefetch and the current song can ask for the same track at once; share the request.
        if let running = inFlight[track.id] {
            return try await running.value
        }
        let client = self.client
        let started = (generations[track.id, default: 0], clearCount)
        let lookup = Task<(LRCLibRecord?, Lyrics), Error> {
            let record = try await client.lyrics(for: track)
            return (record, Lyrics(record: record, trackDuration: track.duration))
        }
        inFlight[track.id] = Task { try await lookup.value.1 }
        defer {
            // A newer lookup may have taken this slot after a choose/clear; leave that one alone.
            if started == (generations[track.id, default: 0], clearCount) { inFlight[track.id] = nil }
        }

        let (record, lyrics) = try await lookup.value
        guard started == (generations[track.id, default: 0], clearCount) else {
            // Something changed while the lookup ran; what's stored now wins.
            return memory[track.id] ?? lyrics
        }
        if let record {
            writeEntry(Entry(record: record, chosenByUser: false, savedAt: now()), trackID: track.id)
        }
        // A miss is only remembered in memory, so it is retried after a relaunch.
        memory[track.id] = lyrics
        return lyrics
    }

    public func candidates(for track: NowPlayingTrack) async throws -> [LRCLibRecord] {
        try await client.candidates(for: track)
    }

    public func choose(_ record: LRCLibRecord, for track: NowPlayingTrack) async throws -> Lyrics {
        // Search results already include the lyrics; fetch by ID only if they were left out.
        var full = record
        if !record.hasSyncedLyrics && !record.hasPlainLyrics && record.instrumental != true,
           let fetched = try await client.get(id: record.id) {
            full = fetched
        }
        generations[track.id, default: 0] += 1
        inFlight[track.id] = nil
        writeEntry(Entry(record: full, chosenByUser: true, savedAt: now()), trackID: track.id)
        let lyrics = Lyrics(record: full, trackDuration: track.duration)
        memory[track.id] = lyrics
        return lyrics
    }

    public func resetChoice(for track: NowPlayingTrack) async throws -> Lyrics {
        generations[track.id, default: 0] += 1
        inFlight[track.id] = nil
        memory[track.id] = nil
        try? FileManager.default.removeItem(at: fileURL(trackID: track.id))
        return try await lyrics(for: track)
    }

    /// True if the user picked this track's lyrics by hand.
    public func isChosenByUser(_ track: NowPlayingTrack) -> Bool {
        readEntry(trackID: track.id)?.chosenByUser ?? false
    }

    /// Deletes every cached lyric (the user's picks too). Returns the number of files removed.
    @discardableResult
    public func clear() -> Int {
        clearCount += 1
        inFlight.removeAll()
        memory.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for file in files where file.pathExtension == "json" {
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// Number of songs with lyrics saved on disk.
    public func cachedCount() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }

    // MARK: Re-checking old misses

    private func needsRecheck(_ entry: Entry, lyrics: Lyrics) -> Bool {
        guard !entry.chosenByUser, !lyrics.isSynced else { return false }
        // Entries from before `savedAt` existed count as old.
        guard let savedAt = entry.savedAt else { return true }
        return now().timeIntervalSince(savedAt) >= Self.recheckInterval
    }

    private func startRecheck(for track: NowPlayingTrack) {
        guard refreshes[track.id] == nil else { return }
        let client = self.client
        let started = (generations[track.id, default: 0], clearCount)
        refreshes[track.id] = Task {
            // Outer nil: the lookup failed. Inner nil: LRCLIB has nothing.
            let record: LRCLibRecord??
            do { record = .some(try await client.lyrics(for: track)) } catch { record = nil }
            self.finishRecheck(track: track, record: record, started: started)
        }
    }

    private func finishRecheck(track: NowPlayingTrack, record: LRCLibRecord??, started: (Int, Int)) {
        refreshes[track.id] = nil
        // The user picked lyrics or cleared the cache meanwhile: leave it alone.
        guard started == (generations[track.id, default: 0], clearCount),
              var entry = readEntry(trackID: track.id), !entry.chosenByUser
        else { return }
        // Offline or LRCLIB down: try again on a later launch.
        guard let record else { return }
        if let record, Lyrics(record: record, trackDuration: track.duration).isSynced {
            entry.record = record
            memory[track.id] = Lyrics(record: record, trackDuration: track.duration)
        }
        // Found nothing better: wait another interval before asking again.
        entry.savedAt = now()
        writeEntry(entry, trackID: track.id)
    }

    /// Waits for background re-checks to finish (for tests).
    func waitForRechecks() async {
        while let task = refreshes.values.first {
            await task.value
        }
    }

    // MARK: Disk

    struct Entry: Codable {
        var record: LRCLibRecord
        var chosenByUser: Bool
        /// When the entry was written. Missing in files from earlier versions.
        var savedAt: Date?
    }

    /// Longest file name used before switching to a hash; file systems allow 255 bytes.
    static let maxPlainFileNameLength = 120

    func fileURL(trackID: String) -> URL {
        // Spotify IDs are base62; anything else (local files) is hex-encoded to stay filename-safe.
        // Long local-file keys (artist + title) would pass the file name limit, so they are hashed.
        let isSafe = !trackID.isEmpty && trackID.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        var name = isSafe ? trackID : "x" + trackID.utf8.map { String(format: "%02x", $0) }.joined()
        if name.utf8.count > Self.maxPlainFileNameLength {
            name = "h" + SHA256Digest.hash(Array(trackID.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return directory.appendingPathComponent("\(name).json")
    }

    private func readEntry(trackID: String) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(trackID: trackID)) else { return nil }
        if let entry = try? JSONDecoder().decode(Entry.self, from: data) {
            return entry
        }
        // Files written by the first version held a bare record.
        return (try? JSONDecoder().decode(LRCLibRecord.self, from: data)).map { Entry(record: $0, chosenByUser: false, savedAt: nil) }
    }

    private func writeEntry(_ entry: Entry, trackID: String) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(trackID: trackID), options: .atomic)
    }
}
