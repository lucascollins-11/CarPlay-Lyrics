import Foundation

/// User preferences, stored in UserDefaults. Every key lives in `Key` so
/// "Delete my data" can remove them all.
@MainActor
final class AppSettings: ObservableObject {
    enum Key: String, CaseIterable {
        case globalOffset
        case trackOffsets
        case demoMode
        case keepScreenAwake
        case driveModeEnabled
        case allowSeeking
        case lyricsTextSize
        /// Written by the first version of the app.
        case legacyTimingOffset = "timingOffset"
    }

    enum TextSize: String, CaseIterable, Identifiable {
        case standard, large, extraLarge
        var id: String { rawValue }
        var label: String {
            switch self {
            case .standard: "Standard"
            case .large: "Large"
            case .extraLarge: "Extra large"
            }
        }
    }

    private let defaults: UserDefaults

    /// Applied to every song, for example to make up for Bluetooth delay. Positive shows lyrics earlier.
    @Published var globalOffset: Double { didSet { defaults.set(globalOffset, forKey: Key.globalOffset.rawValue) } }
    @Published var trackOffsets: [String: Double] { didSet { defaults.set(trackOffsets, forKey: Key.trackOffsets.rawValue) } }
    @Published var demoMode: Bool { didSet { defaults.set(demoMode, forKey: Key.demoMode.rawValue) } }
    @Published var keepScreenAwake: Bool { didSet { defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake.rawValue) } }
    /// Show lyrics as a Live Activity (Lock Screen, Dynamic Island, CarPlay Dashboard).
    @Published var driveModeEnabled: Bool { didSet { defaults.set(driveModeEnabled, forKey: Key.driveModeEnabled.rawValue) } }
    /// Tap a lyric line on the iPhone to jump there (needs an extra Spotify permission and Premium).
    @Published var allowSeeking: Bool { didSet { defaults.set(allowSeeking, forKey: Key.allowSeeking.rawValue) } }
    @Published var lyricsTextSize: TextSize { didSet { defaults.set(lyricsTextSize.rawValue, forKey: Key.lyricsTextSize.rawValue) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The first version stored one global offset under "timingOffset".
        if defaults.object(forKey: Key.globalOffset.rawValue) == nil,
           let legacy = defaults.object(forKey: Key.legacyTimingOffset.rawValue) as? Double {
            defaults.set(legacy, forKey: Key.globalOffset.rawValue)
            defaults.removeObject(forKey: Key.legacyTimingOffset.rawValue)
        }
        globalOffset = defaults.double(forKey: Key.globalOffset.rawValue)
        trackOffsets = defaults.dictionary(forKey: Key.trackOffsets.rawValue) as? [String: Double] ?? [:]
        demoMode = defaults.bool(forKey: Key.demoMode.rawValue)
        keepScreenAwake = defaults.bool(forKey: Key.keepScreenAwake.rawValue)
        driveModeEnabled = defaults.bool(forKey: Key.driveModeEnabled.rawValue)
        allowSeeking = defaults.bool(forKey: Key.allowSeeking.rawValue)
        lyricsTextSize = TextSize(rawValue: defaults.string(forKey: Key.lyricsTextSize.rawValue) ?? "") ?? .standard
    }

    /// Removes every stored preference and resets the published values.
    func deleteAll() {
        for key in Key.allCases {
            defaults.removeObject(forKey: key.rawValue)
        }
        globalOffset = 0
        trackOffsets = [:]
        demoMode = false
        keepScreenAwake = false
        driveModeEnabled = false
        allowSeeking = false
        lyricsTextSize = .standard
        // The didSet observers wrote defaults back; remove them again so nothing is left behind.
        for key in Key.allCases {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}
