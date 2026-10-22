import Foundation
import Network

/// Tells the model when the network comes back, so lyrics catch up with a song
/// change made during a dead zone right away instead of after the retry backoff.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private var wasSatisfied = true
    private let onRestored: @MainActor () -> Void

    init(onRestored: @escaping @MainActor () -> Void) {
        self.onRestored = onRestored
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if satisfied && !self.wasSatisfied { self.onRestored() }
                self.wasSatisfied = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    deinit {
        monitor.cancel()
    }
}
