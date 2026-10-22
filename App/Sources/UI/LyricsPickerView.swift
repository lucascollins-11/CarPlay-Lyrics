import LyricsCore
import SwiftUI

/// "Wrong lyrics?": every version LRCLIB has for this song, best match first.
struct LyricsPickerView: View {
    @EnvironmentObject private var model: NowPlayingModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [LRCLibRecord]?
    @State private var errorMessage: String?
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Group {
                if let candidates {
                    if candidates.isEmpty {
                        ContentUnavailableView("No other versions", systemImage: "text.magnifyingglass",
                                               description: Text("LRCLIB has nothing else for this song. Anyone can add lyrics at lrclib.net."))
                    } else {
                        list(candidates)
                    }
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't search LRCLIB", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else {
                    ProgressView("Searching LRCLIB…")
                }
            }
            .navigationTitle("Choose lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
            .disabled(isApplying)
        }
    }

    private func list(_ records: [LRCLibRecord]) -> some View {
        List {
            if model.snapshot.lyricsChosenByUser {
                Section {
                    Button("Go back to the automatic match") {
                        apply { try await model.resetLyricsChoice() }
                    }
                }
            }
            Section {
                ForEach(records, id: \.id) { record in
                    Button {
                        apply { try await model.chooseLyrics(record) }
                    } label: {
                        CandidateRow(record: record, trackDuration: model.snapshot.track?.duration)
                    }
                    .tint(.primary)
                }
            } footer: {
                Text("Your choice is remembered for this song on this iPhone.")
            }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            candidates = try await model.lyricCandidates()
        } catch {
            candidates = nil
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ action: @escaping () async throws -> Void) {
        isApplying = true
        Task {
            defer { isApplying = false }
            do {
                try await action()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                candidates = nil
            }
        }
    }
}

private struct CandidateRow: View {
    let record: LRCLibRecord
    let trackDuration: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.trackName ?? "Untitled").font(.headline)
            Text([record.artistName, record.albumName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                badge
                if let duration = record.duration {
                    Text(Self.format(duration))
                    if let trackDuration, abs(duration - trackDuration) > 3 {
                        Text("different length").foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let preview {
                Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var badge: some View {
        if record.hasSyncedLyrics {
            Label("Synced", systemImage: "clock").labelStyle(.titleAndIcon).foregroundStyle(Color.appAccent)
        } else if record.hasPlainLyrics {
            Text("Not synced")
        } else if record.instrumental == true {
            Text("Instrumental")
        }
    }

    private var preview: String? {
        let source = record.plainLyrics ?? record.syncedLyrics.map { LRCParser.parse($0).map(\.text).joined(separator: "\n") }
        return source?.split(separator: "\n").prefix(2).joined(separator: " / ")
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
