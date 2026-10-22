import LyricsCore
import SwiftUI

struct LyricsScreen: View {
    @EnvironmentObject private var model: NowPlayingModel
    @EnvironmentObject private var driveMode: DriveModeController
    @State private var showSettings = false
    @State private var showPicker = false

    var body: some View {
        let snapshot = model.snapshot
        NavigationStack {
            VStack(spacing: 0) {
                if let track = snapshot.track {
                    TrackHeader(track: track, isPlaying: snapshot.isPlaying, isDemo: snapshot.isDemo)
                    Divider().overlay(Color.white.opacity(0.2))
                    LyricsBody(snapshot: snapshot)
                    LyricsFooter(snapshot: snapshot, showPicker: $showPicker)
                } else {
                    Spacer()
                    NothingPlayingView(problem: snapshot.problem)
                    Spacer()
                }
                if let problem = snapshot.problem, snapshot.track != nil {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.top, 6)
                        .accessibilityIdentifier("problemBanner")
                }
                ControlsBar()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(snapshot.isDemo ? "Demo" : "Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    DriveModeButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settingsButton")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showPicker) { LyricsPickerView() }
            .alert("Couldn't jump to that line", isPresented: Binding(
                get: { model.seekMessage != nil },
                set: { if !$0 { model.seekMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.seekMessage ?? "")
            }
            .refreshable { model.refreshNow() }
        }
    }
}

private struct NothingPlayingView: View {
    let problem: String?
    @EnvironmentObject private var model: NowPlayingModel

    var body: some View {
        ContentUnavailableView {
            Label(problem == nil ? "Nothing playing" : "Can't reach Spotify", systemImage: problem == nil ? "music.note" : "wifi.exclamationmark")
        } description: {
            if let problem {
                Text(problem)
            } else {
                Text("Play a song on Spotify, on this iPhone or any other device. Podcasts, Private Sessions and local files without details don't show lyrics.")
            }
        } actions: {
            Button("Check again") { model.refreshNow() }
                .accessibilityIdentifier("checkAgainButton")
        }
        .accessibilityIdentifier("nothingPlaying")
    }
}

private struct TrackHeader: View {
    let track: NowPlayingTrack
    let isPlaying: Bool
    let isDemo: Bool
    @EnvironmentObject private var model: NowPlayingModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: track.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.12).overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.7)))
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(2)
                    .accessibilityIdentifier("trackTitle")
                Text(track.artistLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                if !isDemo {
                    // Spotify attribution and a way back to the track (Spotify branding guidelines).
                    Button {
                        if let url = URL(string: "https://open.spotify.com/track/\(track.id)") { openURL(url) }
                    } label: {
                        Label("Open in Spotify", systemImage: "arrow.up.forward.app")
                            .font(.caption.weight(.semibold))
                    }
                    .tint(Color.spotifyGreen)
                    .disabled(track.id.hasPrefix("local:"))
                }
            }
            Spacer(minLength: 0)
            if isDemo {
                Button {
                    model.toggleDemoPlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)
                }
                .tint(.white)
                .accessibilityLabel(isPlaying ? "Pause demo" : "Play demo")
                .accessibilityIdentifier("demoPlayPause")
            } else if !isPlaying {
                Image(systemName: "pause.fill")
                    .foregroundStyle(.white.opacity(0.75))
                    .accessibilityLabel("Paused")
            }
        }
        .padding()
        .accessibilityElement(children: .contain)
    }
}

private struct LyricsBody: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        switch snapshot.lyrics {
        case .none, .loading:
            centered { ProgressView("Finding lyrics…").tint(.white) }
        case .failed(let message):
            centered {
                Label("\(message). Trying again shortly.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .loaded(.notFound):
            centered {
                Label("No lyrics for this song on LRCLIB", systemImage: "text.badge.xmark")
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .loaded(.instrumental):
            centered {
                Label("Instrumental", systemImage: "pianokeys").foregroundStyle(.white.opacity(0.8))
            }
        case .loaded(.plain(let lines)):
            PlainLyricsView(lines: lines)
        case .loaded(.synced(let timeline)):
            SyncedLyricsView(timeline: timeline, currentLine: snapshot.currentLine)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content().multilineTextAlignment(.center).padding(); Spacer() }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("lyricsStatus")
    }
}

private struct PlainLyricsView: View {
    let lines: [String]
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("These lyrics aren't time-synced.", systemImage: "clock.badge.xmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(settings.lyricsTextSize.font.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .accessibilityIdentifier("plainLyrics")
    }
}

private struct SyncedLyricsView: View {
    let timeline: LyricsTimeline
    let currentLine: Int?
    @EnvironmentObject private var model: NowPlayingModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 80).id(-1)
                    ForEach(Array(timeline.lines.enumerated()), id: \.offset) { index, line in
                        LyricLineRow(
                            text: line.isGap ? LyricsDisplay.gapText : line.text,
                            isGap: line.isGap,
                            state: state(for: index),
                            font: settings.lyricsTextSize.font,
                            canSeek: model.canSeek,
                            highContrast: contrast == .increased,
                            reduceMotion: reduceMotion
                        ) {
                            Task { await model.seek(toLine: index) }
                        }
                        .id(index)
                    }
                    Color.clear.frame(height: 240)
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("syncedLyrics")
            .onChange(of: currentLine, initial: true) { _, line in
                if reduceMotion {
                    proxy.scrollTo(line ?? -1, anchor: UnitPoint(x: 0, y: 0.3))
                } else {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        proxy.scrollTo(line ?? -1, anchor: UnitPoint(x: 0, y: 0.3))
                    }
                }
            }
        }
    }

    private func state(for index: Int) -> LyricLineRow.LineState {
        guard let currentLine else { return .upcoming }
        if index == currentLine { return .current }
        return index < currentLine ? .past : .upcoming
    }
}

struct LyricLineRow: View {
    enum LineState { case past, current, upcoming }

    let text: String
    let isGap: Bool
    let state: LineState
    let font: Font
    let canSeek: Bool
    let highContrast: Bool
    let reduceMotion: Bool
    let seek: () -> Void

    var body: some View {
        let label = Text(text)
            .font(font.weight(.bold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(state == .current && !reduceMotion ? 1.03 : 1, anchor: .leading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: state)
            .accessibilityLabel(isGap ? "Instrumental break" : text)
            .accessibilityAddTraits(state == .current ? .isSelected : [])
            .accessibilityIdentifier(state == .current ? "currentLine" : "lyricLine")

        if canSeek {
            Button(action: seek) { label }
                .buttonStyle(.plain)
                .accessibilityHint("Jumps the song to this line")
        } else {
            label
        }
    }

    /// Every state stays above 4.5:1 contrast on black (WCAG AA).
    private var color: Color {
        switch state {
        case .current: .white
        case .upcoming: .white.opacity(highContrast ? 0.85 : 0.68)
        case .past: .white.opacity(highContrast ? 0.8 : 0.58)
        }
    }
}

private struct LyricsFooter: View {
    let snapshot: NowPlayingSnapshot
    @Binding var showPicker: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(snapshot.isDemo ? "Demo lyrics" : "Lyrics from LRCLIB")
            if snapshot.lyricsChosenByUser {
                Text("· chosen by you")
            }
            Spacer()
            if !snapshot.isDemo, case .loaded = snapshot.lyrics {
                Button("Wrong lyrics?") { showPicker = true }
                    .accessibilityIdentifier("wrongLyricsButton")
            } else if !snapshot.isDemo, case .failed = snapshot.lyrics {
                Button("Search") { showPicker = true }
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.7))
        .tint(Color.appAccent)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}

/// Timing nudges for the current song.
private struct ControlsBar: View {
    @EnvironmentObject private var model: NowPlayingModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let offset = model.snapshot.trackOffset
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 16))
        layout {
            HStack(spacing: 16) {
                Button { model.adjustTrackOffset(by: -0.25) } label: {
                    Label("Later", systemImage: "minus.circle.fill").labelStyle(.iconOnly).font(.title2)
                }
                .accessibilityLabel("Show lyrics later")
                .accessibilityIdentifier("offsetLater")

                VStack(spacing: 0) {
                    Text("This song").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    Text(Self.format(offset)).font(.callout.monospacedDigit())
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Timing for this song")
                .accessibilityValue(Self.spoken(offset))
                .accessibilityAction(named: "Reset timing") { model.resetTrackOffset() }
                .accessibilityIdentifier("offsetValue")

                Button { model.adjustTrackOffset(by: 0.25) } label: {
                    Label("Earlier", systemImage: "plus.circle.fill").labelStyle(.iconOnly).font(.title2)
                }
                .accessibilityLabel("Show lyrics earlier")
                .accessibilityIdentifier("offsetEarlier")
            }
            if !typeSize.isAccessibilitySize { Spacer() }
            HStack(spacing: 16) {
                Button("Reset") { model.resetTrackOffset() }
                    .disabled(offset == 0)
                    .accessibilityLabel("Reset timing")
                    .accessibilityIdentifier("offsetReset")
                Button { model.refreshNow() } label: {
                    Image(systemName: "arrow.clockwise").font(.title3)
                }
                .accessibilityLabel("Refresh")
            }
        }
        .tint(Color.appAccent)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    static func format(_ offset: Double) -> String {
        offset == 0 ? "0.00s" : String(format: "%+.2fs", offset)
    }

    static func spoken(_ offset: Double) -> String {
        if offset == 0 { return "no adjustment" }
        let amount = String(format: "%.2f", abs(offset))
        return offset > 0 ? "\(amount) seconds earlier" : "\(amount) seconds later"
    }
}

private struct DriveModeButton: View {
    @EnvironmentObject private var driveMode: DriveModeController

    var body: some View {
        Button {
            if driveMode.isRunning { driveMode.stop() } else { driveMode.start() }
        } label: {
            Label(driveMode.isRunning ? "Drive mode on" : "Drive mode",
                  systemImage: driveMode.isRunning ? "car.fill" : "car")
        }
        .tint(driveMode.isRunning ? Color.appAccent : .white)
        .accessibilityHint(driveMode.isRunning
                           ? "Stops showing lyrics on the Lock Screen and CarPlay Dashboard"
                           : "Shows lyrics on the Lock Screen and the CarPlay Dashboard")
        .accessibilityIdentifier("driveModeButton")
    }
}

extension AppSettings.TextSize {
    var font: Font {
        switch self {
        case .standard: .title2
        case .large: .title
        case .extraLarge: .largeTitle
        }
    }
}
