import ActivityKit
import Combine
import Foundation
import LyricsCore

/// Drive mode puts the current lyric line in a Live Activity, which iOS 26
/// shows on the CarPlay Dashboard (and on the Lock Screen and Dynamic Island
/// everywhere). It keeps the app alive in the background while it runs, and
/// switches itself off when nothing has played for a while.
@MainActor
final class DriveModeController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var message: String?

    /// Stop after this long with nothing playing, to save battery.
    static let idleTimeout: TimeInterval = 15 * 60
    /// Minimum time between two Live Activity updates.
    static let minimumUpdateInterval: TimeInterval = 0.4

    private let model: NowPlayingModel
    private let keepAlive = BackgroundKeepAlive()
    private var activity: Activity<LyricsActivityAttributes>?
    private var subscription: AnyCancellable?
    private var stateTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastSent: LiveLyricsContent?
    private var pending: LiveLyricsContent?
    private var lastUpdateAt: Date = .distantPast
    private var idleSince: Date?

    static let client = "driveMode"

    init(model: NowPlayingModel) {
        self.model = model
    }

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Re-attaches to a Live Activity left over from a previous launch.
    func restoreIfNeeded() {
        let existing = Activity<LyricsActivityAttributes>.activities
        guard !existing.isEmpty else { return }
        if model.settings.driveModeEnabled, let first = existing.first {
            for extra in existing.dropFirst() {
                Task { await extra.end(nil, dismissalPolicy: .immediate) }
            }
            attach(to: first)
        } else {
            for activity in existing {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

    /// Starts Drive mode. Must be called while the app is in the foreground.
    func start() {
        guard !isRunning else { return }
        guard isSupported else {
            message = "Live Activities are turned off for Lyrics. Turn them on in Settings > Lyrics."
            return
        }
        let content = LiveLyricsContent.make(for: model.snapshot, position: model.estimatedPosition())
        do {
            let activity = try Activity.request(
                attributes: LyricsActivityAttributes(startedAt: Date()),
                content: ActivityContent(state: content, staleDate: staleDate(for: content)),
                pushType: nil
            )
            lastSent = content
            attach(to: activity)
            model.settings.driveModeEnabled = true
            message = nil
        } catch {
            message = "Couldn't start Drive mode: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning || activity != nil else { return }
        let activity = self.activity
        detach()
        model.settings.driveModeEnabled = false
        if let activity {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func attach(to activity: Activity<LyricsActivityAttributes>) {
        self.activity = activity
        isRunning = true
        idleSince = nil
        do {
            try keepAlive.start()
        } catch {
            message = "Drive mode may pause in the background: \(error.localizedDescription)"
        }
        model.setActive(true, client: Self.client)

        subscription = model.$snapshot
            .removeDuplicates()
            .sink { [weak self] snapshot in self?.snapshotChanged(snapshot) }

        // Refresh the stale date during long instrumentals, and check for idling.
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.heartbeat()
            }
        }

        // Notice when the user or the system (8-hour limit) ends the activity.
        stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                if state == .ended || state == .dismissed {
                    self?.activityEnded()
                    return
                }
            }
        }
    }

    private func detach() {
        subscription = nil
        stateTask?.cancel()
        stateTask = nil
        updateTask?.cancel()
        updateTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        activity = nil
        lastSent = nil
        pending = nil
        keepAlive.stop()
        model.setActive(false, client: Self.client)
        isRunning = false
    }

    private func activityEnded() {
        detach()
        model.settings.driveModeEnabled = false
        message = "Drive mode ended. Start it again before your next drive."
    }

    /// Switches off after a long stretch of silence. Returns true if it stopped.
    private func stopIfIdle(_ snapshot: NowPlayingSnapshot) -> Bool {
        if snapshot.track != nil, snapshot.isPlaying {
            idleSince = nil
        } else if idleSince == nil {
            idleSince = Date()
        } else if let idleSince, Date().timeIntervalSince(idleSince) > Self.idleTimeout {
            stop()
            message = "Drive mode stopped because nothing was playing."
            return true
        }
        return false
    }

    private func heartbeat() {
        let snapshot = model.snapshot
        guard !stopIfIdle(snapshot) else { return }
        pending = LiveLyricsContent.make(for: snapshot, position: model.estimatedPosition())
        scheduleUpdate()
    }

    private func snapshotChanged(_ snapshot: NowPlayingSnapshot) {
        guard !stopIfIdle(snapshot) else { return }
        let content = LiveLyricsContent.make(for: snapshot, position: model.estimatedPosition())
        if let lastSent, lastSent.showsSameText(as: content) { return }
        pending = content
        scheduleUpdate()
    }

    /// Sends the newest content, at most once per `minimumUpdateInterval`.
    private func scheduleUpdate() {
        guard updateTask == nil else { return }
        let wait = max(0, Self.minimumUpdateInterval - Date().timeIntervalSince(lastUpdateAt))
        updateTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.updateTask = nil
            guard let activity = self.activity, let content = self.pending else { return }
            self.pending = nil
            self.lastSent = content
            self.lastUpdateAt = Date()
            await activity.update(ActivityContent(state: content, staleDate: self.staleDate(for: content)))
        }
    }

    /// If updates stop arriving (the app was suspended), iOS greys the line out instead of showing a stale one.
    private func staleDate(for content: LiveLyricsContent) -> Date {
        Date().addingTimeInterval(content.isPlaying ? 45 : 15 * 60)
    }
}
