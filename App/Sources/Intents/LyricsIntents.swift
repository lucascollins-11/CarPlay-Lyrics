import AppIntents
import Foundation

/// Starts Drive mode without opening the app, so it can run from a Shortcuts
/// automation "When CarPlay connects". A LiveActivityIntent may start a Live
/// Activity while the app is in the background.
struct StartDriveModeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Drive mode"
    static let description = IntentDescription("Shows the current lyric line on the CarPlay Dashboard and the Lock Screen.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let driveMode = AppServices.shared.driveMode
        if driveMode.start(), driveMode.message == nil {
            return .result(dialog: "Drive mode is on.")
        }
        return .result(dialog: "\(driveMode.message ?? "Drive mode couldn't start.")")
    }
}

struct StopDriveModeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Drive mode"
    static let description = IntentDescription("Removes the lyrics from the CarPlay Dashboard and the Lock Screen.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppServices.shared.driveMode.stop()
        return .result(dialog: "Drive mode is off.")
    }
}

/// "Lyrics earlier" / "Lyrics later" by voice, so timing can be fixed in the car without touching the phone.
struct LyricsEarlierIntent: AppIntent {
    static let title: LocalizedStringResource = "Show lyrics earlier"
    static let description = IntentDescription("Shows this song's lyrics a quarter of a second earlier.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppServices.shared.model
        guard model.snapshot.track != nil else { return .result(dialog: "Nothing is playing.") }
        model.adjustTrackOffset(by: 0.25)
        return .result(dialog: "Lyrics earlier.")
    }
}

struct LyricsLaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Show lyrics later"
    static let description = IntentDescription("Shows this song's lyrics a quarter of a second later.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppServices.shared.model
        guard model.snapshot.track != nil else { return .result(dialog: "Nothing is playing.") }
        model.adjustTrackOffset(by: -0.25)
        return .result(dialog: "Lyrics later.")
    }
}

struct LyricsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartDriveModeIntent(), phrases: ["Start Drive mode in \(.applicationName)"],
                    shortTitle: "Start Drive mode", systemImageName: "car")
        AppShortcut(intent: StopDriveModeIntent(), phrases: ["Stop Drive mode in \(.applicationName)"],
                    shortTitle: "Stop Drive mode", systemImageName: "car.side")
        AppShortcut(intent: LyricsEarlierIntent(), phrases: ["Show \(.applicationName) earlier", "\(.applicationName) earlier"],
                    shortTitle: "Lyrics earlier", systemImageName: "backward")
        AppShortcut(intent: LyricsLaterIntent(), phrases: ["Show \(.applicationName) later", "\(.applicationName) later"],
                    shortTitle: "Lyrics later", systemImageName: "forward")
    }
}
