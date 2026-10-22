import Foundation

/// Settings that come from `Config.xcconfig` through Info.plist.
enum AppConfig {
    /// The Client ID of your app on https://developer.spotify.com/dashboard.
    static var spotifyClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    static var isSpotifyConfigured: Bool {
        let id = spotifyClientID
        return !id.isEmpty && !id.hasPrefix("$(") && id != "YOUR_SPOTIFY_CLIENT_ID"
    }

    /// Must be added, exactly, as a Redirect URI in the Spotify dashboard.
    static let spotifyRedirectURI = "carplaylyrics://callback"
    static let spotifyCallbackScheme = "carplaylyrics"
    static let spotifyScopes = ["user-read-currently-playing", "user-read-playback-state"]

    static var lrclibUserAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "CarPlayLyrics/\(version) (personal iOS app)"
    }
}
