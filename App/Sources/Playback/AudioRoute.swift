import AVFoundation
import Foundation

/// Kinds of audio output that add noticeably different delays between what
/// Spotify reports and what you hear. Each gets its own timing adjustment.
enum AudioRouteKind: String, CaseIterable, Identifiable, Sendable {
    case car, bluetooth, airPlay, wired, speaker

    var id: String { rawValue }

    var label: String {
        switch self {
        case .car: "CarPlay"
        case .bluetooth: "Bluetooth"
        case .airPlay: "AirPlay"
        case .wired: "Headphones (wired)"
        case .speaker: "iPhone speaker"
        }
    }

    init(port: AVAudioSession.Port?) {
        switch port {
        case .carAudio?: self = .car
        case .bluetoothA2DP?, .bluetoothLE?, .bluetoothHFP?: self = .bluetooth
        case .airPlay?: self = .airPlay
        case .headphones?, .usbAudio?, .lineOut?, .HDMI?, .displayPort?: self = .wired
        default: self = .speaker
        }
    }

    /// Where the phone's audio goes right now. If Spotify plays on another device
    /// (a speaker, the car's own Spotify), this is still the phone's route.
    static var current: AudioRouteKind {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        // CarPlay wins if it is one of several outputs.
        if outputs.contains(where: { $0.portType == .carAudio }) { return .car }
        return AudioRouteKind(port: outputs.first?.portType)
    }
}

/// Follows the phone's audio route and tells the model, so the right timing adjustment applies.
@MainActor
final class AudioRouteMonitor {
    /// Only set in init and read in deinit.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(onChange: @escaping @MainActor @Sendable (AudioRouteKind) -> Void) {
        onChange(.current)
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange(.current) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
