import ActivityKit
import Foundation
import LyricsCore

/// The Live Activity that shows the current lyric line on the Lock Screen,
/// in the Dynamic Island and on the CarPlay Dashboard (iOS 26+).
/// Compiled into both the app and the widget extension.
struct LyricsActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveLyricsContent

    /// When Drive mode started. Live Activities end after 8 hours.
    var startedAt: Date
}
