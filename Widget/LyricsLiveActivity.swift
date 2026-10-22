import ActivityKit
import LyricsCore
import SwiftUI
import WidgetKit

@main
struct LyricsWidgetBundle: WidgetBundle {
    var body: some Widget {
        LyricsLiveActivity()
    }
}

/// The current lyric line on the Lock Screen, in the Dynamic Island, and on
/// the CarPlay Dashboard (the `.small` family, iOS 26+).
struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsActivityView(content: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "quote.bubble.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.isPlaying {
                        Image(systemName: "pause.fill").accessibilityLabel("Paused")
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LyricLinesView(content: context.state, isStale: context.isStale, compact: false)
                }
            } compactLeading: {
                Image(systemName: "quote.bubble.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            } compactTrailing: {
                Text(context.state.current)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 64)
            } minimal: {
                Image(systemName: "quote.bubble.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Lyrics")
            }
        }
        // `.small` is what the CarPlay Dashboard (and Apple Watch) show.
        .supplementalActivityFamilies([.small, .medium])
    }
}

struct LyricsActivityView: View {
    let content: LiveLyricsContent
    let isStale: Bool
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            // CarPlay Dashboard / Watch: big current line, short next line.
            VStack(alignment: .leading, spacing: 2) {
                LyricLinesView(content: content, isStale: isStale, compact: true)
            }
            .padding(8)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "quote.bubble.fill").foregroundStyle(.green).accessibilityHidden(true)
                    Text(content.artist.isEmpty ? content.title : "\(content.title) · \(content.artist)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer()
                    if !content.isPlaying {
                        Image(systemName: "pause.fill").font(.caption).foregroundStyle(.white.opacity(0.75)).accessibilityLabel("Paused")
                    }
                }
                LyricLinesView(content: content, isStale: isStale, compact: false)
            }
            .padding()
        }
    }
}

struct LyricLinesView: View {
    let content: LiveLyricsContent
    let isStale: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 4) {
            Text(content.current)
                .font(compact ? .headline : .title3.weight(.bold))
                .foregroundStyle(isStale ? .white.opacity(0.6) : .white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(content.current == LyricsDisplay.gapText ? "Instrumental break" : content.current)
            if let next = content.next {
                Text(next)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .accessibilityLabel("Next: \(next)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
