import Foundation
import LyricsCore

/// Looks up lyrics on LRCLIB and caches them by Spotify track ID, in memory
/// and on disk, so a song you replay in the car loads instantly and offline.
actor LyricsRepository {
    static let shared = LyricsRepository()

    private let client = LRCLibClient(userAgent: AppConfig.lrclibUserAgent)
    private var memory: [String: Lyrics] = [:]
    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func lyrics(for track: NowPlayingTrack) async throws -> Lyrics {
        if let cached = memory[track.id] {
            return cached
        }
        if let record = readRecord(trackID: track.id) {
            let lyrics = Lyrics(record: record)
            memory[track.id] = lyrics
            return lyrics
        }
        let record = try await client.lyrics(for: track)
        if let record {
            writeRecord(record, trackID: track.id)
        }
        // A miss is only remembered in memory, so it is retried after a relaunch.
        let lyrics = Lyrics(record: record)
        memory[track.id] = lyrics
        return lyrics
    }

    private func fileURL(trackID: String) -> URL {
        let safe = trackID.filter { $0.isLetter || $0.isNumber }
        return directory.appendingPathComponent("\(safe).json")
    }

    private func readRecord(trackID: String) -> LRCLibRecord? {
        guard let data = try? Data(contentsOf: fileURL(trackID: trackID)) else { return nil }
        return try? JSONDecoder().decode(LRCLibRecord.self, from: data)
    }

    private func writeRecord(_ record: LRCLibRecord, trackID: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: fileURL(trackID: trackID), options: .atomic)
    }
}
