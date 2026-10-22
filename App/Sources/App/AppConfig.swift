import Foundation

/// Settings that come from `Config.xcconfig` through Info.plist, plus fixed app constants.
enum AppConfig {
    /// The Client ID of your app on https://developer.spotify.com/dashboard.
    static var spotifyClientID: String { infoString("SpotifyClientID") }

    static var isSpotifyConfigured: Bool {
        let id = spotifyClientID
        return !id.isEmpty && !id.hasPrefix("$(") && id != "YOUR_SPOTIFY_CLIENT_ID"
    }

    /// Must be added, exactly, as a Redirect URI in the Spotify dashboard.
    static let spotifyRedirectURI = "carplaylyrics://callback"
    static let spotifyCallbackScheme = "carplaylyrics"

    /// Read-only access to what is playing. Nothing else. (Locked by a unit test.)
    static let spotifyScopes = ["user-read-currently-playing", "user-read-playback-state"]
    /// Added only when the user turns on "Tap a line to jump there" in Settings.
    static let spotifySeekScope = "user-modify-playback-state"

    static var publisherName: String {
        let value = infoString("PublisherName")
        return value.isEmpty || value.hasPrefix("$(") || value == "YOUR_NAME" ? "the developer" : value
    }

    static var supportEmail: String? {
        let value = infoString("SupportEmail")
        return value.isEmpty || value.hasPrefix("$(") || !value.contains("@") ? nil : value
    }

    static let sourceURL = URL(string: "https://github.com/lucascollins-11/CarPlay-Lyrics")!
    static let lrclibURL = URL(string: "https://lrclib.net")!
    static let spotifyAppsURL = URL(string: "https://www.spotify.com/account/apps/")!

    static var version: String {
        let short = infoString("CFBundleShortVersionString")
        let build = infoString("CFBundleVersion")
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    /// No device or user identifiers, per LRCLIB's request to name the app.
    static var lrclibUserAgent: String {
        "CarPlayLyrics/\(infoString("CFBundleShortVersionString")) (+\(sourceURL.absoluteString))"
    }

    private static func infoString(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

/// Launch arguments used by the UI tests and for trying the app.
enum LaunchOptions {
    /// Start in demo mode regardless of the saved setting.
    static var forceDemo: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }
    /// Wipe settings and caches at launch so every UI test starts clean.
    static var resetState: Bool { ProcessInfo.processInfo.arguments.contains("-resetState") }
    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-uiTesting") }
}
