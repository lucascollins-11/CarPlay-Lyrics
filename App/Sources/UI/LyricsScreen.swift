import LyricsCore
import SwiftUI

struct LyricsScreen: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var model: NowPlayingModel

    var body: some View {
        let snapshot = model.snapshot
        VStack(spacing: 0) {
            if let track = snapshot.track {
                TrackHeader(track: track, isPlaying: snapshot.isPlaying)
                Divider().opacity(0.3)
                LyricsBody(lyrics: snapshot.lyrics, currentLine: snapshot.currentLine)
            } else {
                Spacer()
                ContentUnavailableView(
                    "Nothing playing",
                    systemImage: "music.note",
                    description: Text("Play a song on Spotify, on this phone or any other device, and the lyrics show up here and in CarPlay.")
                )
                Spacer()
            }
            if let problem = snapshot.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
            ControlsBar()
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private struct TrackHeader: View {
    let track: NowPlayingTrack
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: track.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.3).overlay(Image(systemName: "music.note"))
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.headline).lineLimit(2)
                Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !isPlaying {
                Image(systemName: "pause.fill").foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

private struct LyricsBody: View {
    let lyrics: NowPlayingModel.LyricsState
    let currentLine: Int?

    var body: some View {
        switch lyrics {
        case .none, .loading:
            centered { ProgressView("Finding lyrics…") }
        case .failed(let message):
            centered { Label(message, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary) }
        case .loaded(.notFound):
            centered { Label("No lyrics found for this song", systemImage: "text.badge.xmark").foregroundStyle(.secondary) }
        case .loaded(.instrumental):
            centered { Label("Instrumental", systemImage: "pianokeys").foregroundStyle(.secondary) }
        case .loaded(.plain(let lines)):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("These lyrics aren't time-synced.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line).font(.title3.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        case .loaded(.synced(let timeline)):
            SyncedLyricsView(timeline: timeline, currentLine: currentLine)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity)
    }
}

private struct SyncedLyricsView: View {
    let timeline: LyricsTimeline
    let currentLine: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 120).id(-1)
                    ForEach(Array(timeline.lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isGap ? "♪" : line.text)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(color(for: index))
                            .scaleEffect(index == currentLine ? 1.04 : 1, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    Color.clear.frame(height: 240)
                }
                .padding(.horizontal, 20)
                .animation(.easeOut(duration: 0.25), value: currentLine)
            }
            .scrollIndicators(.hidden)
            .onChange(of: currentLine, initial: true) { _, line in
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(line ?? -1, anchor: UnitPoint(x: 0, y: 0.35))
                }
            }
        }
    }

    private func color(for index: Int) -> Color {
        guard let currentLine else { return .white.opacity(0.45) }
        if index == currentLine { return .white }
        return index < currentLine ? .white.opacity(0.3) : .white.opacity(0.5)
    }
}

private struct ControlsBar: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var model: NowPlayingModel

    var body: some View {
        HStack {
            Button { model.adjustOffset(by: -0.25) } label: {
                Image(systemName: "minus.circle.fill").font(.title2)
            }
            .accessibilityLabel("Show lyrics later")

            VStack(spacing: 0) {
                Text("Timing").font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%+.2fs", model.timingOffset)).font(.callout.monospacedDigit())
            }
            .frame(minWidth: 70)
            .onTapGesture(count: 2) { model.timingOffset = 0 }

            Button { model.adjustOffset(by: 0.25) } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            .accessibilityLabel("Show lyrics earlier")

            Spacer()

            Button { model.refreshNow() } label: {
                Image(systemName: "arrow.clockwise").font(.title3)
            }
            .accessibilityLabel("Refresh")

            Menu {
                Button("Reset timing") { model.timingOffset = 0 }
                Button("Sign out of Spotify", role: .destructive) { auth.signOut() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .padding(.leading, 12)
        }
        .tint(.green)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}
