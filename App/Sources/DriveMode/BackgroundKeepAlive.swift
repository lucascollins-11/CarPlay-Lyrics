import AVFoundation
import Foundation

/// Keeps the app running in the background while Drive mode is on, so it can
/// keep following Spotify and updating the Live Activity.
///
/// It holds a silent, mixable audio session: Spotify keeps playing, nothing is
/// ducked, and because the session mixes with others the app never becomes the
/// "Now Playing" app. This needs the `audio` background mode, which is fine for
/// a copy you install yourself but would not pass App Store review.
@MainActor
final class BackgroundKeepAlive {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

        let player = try AVAudioPlayer(data: Self.silentWAV())
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        player.play()
        self.player = player
        isRunning = true

        let center = NotificationCenter.default
        observers = [
            // A call, Siri or a navigation prompt interrupts every session; pick up again afterwards.
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                // (The "app was suspended" interruption reason no longer exists since iOS 16; we need iOS 18.)
                guard rawType == AVAudioSession.InterruptionType.ended.rawValue else { return }
                MainActor.assumeIsolated { self?.resume() }
            },
            // Plugging in or unplugging CarPlay, Bluetooth or headphones can stop the player.
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            },
        ]
    }

    func stop() {
        guard isRunning else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        player?.stop()
        player = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resume() {
        guard isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if player?.isPlaying != true { player?.play() }
    }

    /// Checked by Drive mode's heartbeat, in case a stop slipped past the notifications.
    /// Returns true if the silent player had stopped and was started again.
    @discardableResult
    func restartIfStopped() -> Bool {
        guard isRunning, player?.isPlaying != true else { return false }
        resume()
        if player?.isPlaying != true { restart() }
        return true
    }

    private func restart() {
        guard isRunning else { return }
        stop()
        try? start()
    }

    /// One second of 16-bit mono silence as a WAV file.
    static func silentWAV(sampleRate: UInt32 = 8000) -> Data {
        let samples = Data(count: Int(sampleRate) * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))          // fmt chunk size
        append(UInt16(1))           // PCM
        append(UInt16(1))           // mono
        append(sampleRate)
        append(sampleRate * 2)      // byte rate
        append(UInt16(2))           // block align
        append(UInt16(16))          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count))
        data.append(samples)
        return data
    }
}
