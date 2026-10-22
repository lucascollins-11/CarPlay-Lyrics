import LyricsCore
import SwiftUI

/// Owns the app's long-lived objects. One instance, shared by the iPhone scene and CarPlay.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let settings: AppSettings
    let auth: SpotifyAuth
    let model: NowPlayingModel
    let driveMode: DriveModeController
    private var networkMonitor: NetworkMonitor?

    private init() {
        if LaunchOptions.resetState {
            Self.wipeForTesting()
        }
        settings = AppSettings()
        auth = SpotifyAuth()
        model = NowPlayingModel(settings: settings, auth: auth, dependencies: .live(auth: auth))
        driveMode = DriveModeController(model: model)
        let model = self.model
        networkMonitor = NetworkMonitor { model.networkRestored() }
        // Also on a background-only launch (CarPlay, a Shortcut), not just when the iPhone UI appears.
        driveMode.restoreIfNeeded()
    }

    /// UI tests start from a clean install.
    private static func wipeForTesting() {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        KeychainTokenStore().delete()
        try? FileManager.default.removeItem(at: AppConfig.lyricsDirectory)
        try? FileManager.default.removeItem(at: AppConfig.legacyLyricsDirectory)
    }
}

@main
struct CarPlayLyricsApp: App {
    private let services = AppServices.shared

    var body: some Scene {
        // The CarPlay scene is declared in Info.plist and handled by CarPlaySceneDelegate.
        WindowGroup {
            RootView()
                .environmentObject(services.settings)
                .environmentObject(services.auth)
                .environmentObject(services.model)
                .environmentObject(services.driveMode)
                .task { services.driveMode.restoreIfNeeded() }
        }
    }
}
