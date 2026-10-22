import SwiftUI

@main
struct CarPlayLyricsApp: App {
    var body: some Scene {
        // The CarPlay scene is declared in Info.plist and handled by CarPlaySceneDelegate.
        WindowGroup {
            RootView()
                .environmentObject(SpotifyAuth.shared)
                .environmentObject(NowPlayingModel.shared)
                .preferredColorScheme(.dark)
        }
    }
}
