import ActivityKit
import AVFoundation
import Combine
import Foundation
import LyricsCore
import os

/// Drive mode puts the current lyric line in a Live Activity, which iOS 26
/// shows on the CarPlay Dashboard (and on the Lock Screen and Dynamic Island
/// everywhere). It keeps the app alive in the background while it runs, and
/// switches itself off after leaving the car or when nothing has played for a
/// while (see `DriveModeIdlePolicy`). What to show and when is decided by
/// `DashboardPlanner` (lines sent slightly early, throttled, short lines merged).
@MainActor
final class DriveModeController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var message: String?
    /// False when iOS refused the background audio (Drive mode started from the background):
    /// the Dashboard line then only updates while Lyrics is open. Retried on every foreground.
    @Published private(set) var keepsRunningInBackground = false

    /// iOS ends a Live Activity after 8 hours; replace it quietly before then when the app is open.
    static let replaceAfter: TimeInterval = 6 * 60 * 60
    /// How often to check the keep-alive and the idle policy.
    static let heartbeatInterval: TimeInterval = 30

    private let model: NowPlayingModel
    private let keepAlive = BackgroundKeepAlive()
    private var activity: Activity<LyricsActivityAttributes>?
    private var subscriptions: Set<AnyCancellable> = []
    private var stateTask: Task<Void, Never>?
    private var planTask: Task<Void, Never>?
    private var planWait: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// The last Live Activity update sent; each waits for the one before, so they arrive in order.
    private var lastUpdate: Task<Void, Never>?
    private var planner = DashboardPlanner()
    private var idlePolicy = DriveModeIdlePolicy()
    private let log = Logger(subsystem: "CarPlayLyrics", category: "DriveMode")

    static let client = "driveMode"

    init(model: NowPlayingModel) {
        self.model = model
    }

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Re-attaches to a Live Activity left over from a previous launch.
    func restoreIfNeeded() {
        guard !isRunning else { return }
        let existing = Activity<LyricsActivityAttributes>.activities
        guard !existing.isEmpty else { return }
        if model.settings.driveModeEnabled, let first = existing.first {
            for extra in existing.dropFirst() {
                Self.end(ActivityBox(extra))
            }
            attach(to: first)
        } else {
            for activity in existing {
                Self.end(ActivityBox(activity))
            }
        }
    }

    /// Starts Drive mode. Works in the foreground, and in the background from
    /// the Start Drive mode shortcut (a LiveActivityIntent). Returns false and
    /// sets `message` if it couldn't start.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard isSupported else {
            message = "Live Activities are turned off for Lyrics. Turn them on in Settings > Lyrics."
            return false
        }
        planner = DashboardPlanner(lead: model.settings.dashboardLead)
        let content = LiveLyricsContent.make(for: model.snapshot, position: model.estimatedPosition())
        do {
            let activity = try Activity.request(
                attributes: LyricsActivityAttributes(startedAt: Date()),
                content: ActivityContent(state: content, staleDate: staleDate(for: content)),
                pushType: nil
            )
            attach(to: activity)
            model.settings.driveModeEnabled = true
            // The first Drive mode is when an expiry warning starts to matter: ask for notifications now.
            BuildExpiryReminder.reschedule(askIfNeeded: true)
            return isRunning
        } catch {
            message = "Couldn't start Drive mode: \(error.localizedDescription)"
            return false
        }
    }

    func stop() {
        guard isRunning || activity != nil else { return }
        let activity = self.activity
        detach()
        model.settings.driveModeEnabled = false
        if let activity {
            Self.end(ActivityBox(activity))
        }
    }

    /// The app came to the foreground: start the background audio if iOS refused it before, and
    /// replace an activity that is close to iOS's 8-hour limit.
    func appBecameActive() {
        guard isRunning, let activity else { return }
        if Date().timeIntervalSince(activity.attributes.startedAt) > Self.replaceAfter {
            stop()
            start()
        } else if !keepsRunningInBackground {
            startKeepAlive()
        }
    }

    private func startKeepAlive() {
        do {
            try keepAlive.start()
            keepsRunningInBackground = true
            message = nil
        } catch {
            // Usually: started from the background (a Shortcut, a restored activity), where iOS refuses
            // to start audio ('!pla'). The Live Activity still shows; opening Lyrics once fixes it.
            keepsRunningInBackground = false
            message = "Drive mode is on, but it can only keep the Dashboard up to date after you open Lyrics once."
            log.error("Keep-alive failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func attach(to activity: Activity<LyricsActivityAttributes>) {
        self.activity = activity
        isRunning = true
        message = nil
        idlePolicy = DriveModeIdlePolicy()
        planner = DashboardPlanner(lead: model.settings.dashboardLead)
        startKeepAlive()
        model.setActive(true, client: Self.client)

        // Re-plan as soon as anything changes; otherwise the plan loop sleeps until the next line.
        model.$snapshot
            .removeDuplicates()
            .sink { [weak self] _ in self?.planWait?.cancel() }
            .store(in: &subscriptions)
        model.settings.$dashboardLead
            .sink { [weak self] lead in
                self?.planner.lead = lead
                self?.planWait?.cancel()
            }
            .store(in: &subscriptions)

        planTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.planAndSend() else { return }
                let wait = Task { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                self?.planWait = wait
                await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
            }
        }

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                self?.heartbeat()
            }
        }

        // Notice when the user or the system (8-hour limit) ends the activity.
        let box = ActivityBox(activity)
        stateTask = Task { [weak self] in
            for await state in box.activity.activityStateUpdates {
                if state == .ended || state == .dismissed {
                    self?.activityEnded()
                    return
                }
            }
        }
    }

    private func detach() {
        subscriptions.removeAll()
        stateTask?.cancel()
        stateTask = nil
        planTask?.cancel()
        planTask = nil
        planWait?.cancel()
        planWait = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        lastUpdate = nil
        activity = nil
        keepAlive.stop()
        keepsRunningInBackground = false
        model.setActive(false, client: Self.client)
        isRunning = false
    }

    private func activityEnded() {
        detach()
        model.settings.driveModeEnabled = false
        message = "Drive mode ended. Start it again before your next drive."
    }

    /// Sends what the planner says, and returns how long to sleep. Nil once Drive mode stopped.
    private func planAndSend() -> TimeInterval? {
        guard isRunning, let activity else { return nil }
        let snapshot = model.snapshot
        guard !stopIfIdle(snapshot) else { return nil }
        let plan = planner.plan(snapshot: snapshot, position: model.estimatedPosition(), now: MonotonicClock.now())
        if let content = plan.send {
            lastUpdate = Self.update(ActivityBox(activity), content: content, staleDate: staleDate(for: content), after: lastUpdate)
        }
        return plan.wakeAfter
    }

    /// Switches off when the policy says so, or right away after signing out. Returns true if it stopped.
    private func stopIfIdle(_ snapshot: NowPlayingSnapshot) -> Bool {
        if !snapshot.isSignedIn, !snapshot.isDemo {
            stop()
            message = "Drive mode stopped because you signed out of Spotify."
            return true
        }
        let playing = snapshot.track != nil && snapshot.isPlaying
        if idlePolicy.shouldStop(isPlaying: playing, inCar: Self.isConnectedToCar, now: MonotonicClock.now()) {
            let leftCar = idlePolicy.leftCarAt != nil
            stop()
            message = leftCar ? "Drive mode stopped a while after CarPlay disconnected." : "Drive mode stopped because nothing was playing."
            return true
        }
        return false
    }

    /// True while audio goes to CarPlay.
    static var isConnectedToCar: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    private func heartbeat() {
        guard isRunning else { return }
        if keepAlive.restartIfStopped() {
            log.notice("Keep-alive audio had stopped; restarted it")
        }
        planWait?.cancel()
    }

    /// If updates stop arriving (the app was suspended), iOS marks the activity stale and the widget says so.
    private func staleDate(for content: LiveLyricsContent) -> Date {
        Date().addingTimeInterval(content.isPlaying ? 45 : 15 * 60)
    }

    // MARK: ActivityKit calls

    /// `Activity` isn't Sendable; it is only ever touched from these helpers and the main actor.
    struct ActivityBox: @unchecked Sendable {
        let activity: Activity<LyricsActivityAttributes>
        init(_ activity: Activity<LyricsActivityAttributes>) { self.activity = activity }
    }

    nonisolated private static func update(_ box: ActivityBox, content: LiveLyricsContent, staleDate: Date,
                                           after previous: Task<Void, Never>?) -> Task<Void, Never> {
        Task {
            await previous?.value
            await box.activity.update(ActivityContent(state: content, staleDate: staleDate))
        }
    }

    nonisolated private static func end(_ box: ActivityBox) {
        Task { await box.activity.end(nil, dismissalPolicy: .immediate) }
    }
}

/// When Drive mode switches itself off. Never while connected to CarPlay, so a
/// stop for fuel or coffee doesn't end it; otherwise after a stretch with nothing
/// playing, or a while after leaving the car even if music carries on in headphones.
/// Times are monotonic seconds, so a change of the phone's clock can't trigger it.
struct DriveModeIdlePolicy {
    /// Not in the car and nothing playing for this long.
    static let idleTimeout: TimeInterval = 15 * 60
    /// This long after CarPlay disconnects, whatever is playing.
    static let afterCarTimeout: TimeInterval = 20 * 60

    private(set) var idleSince: TimeInterval?
    private(set) var leftCarAt: TimeInterval?
    private var wasInCar = false

    mutating func shouldStop(isPlaying: Bool, inCar: Bool, now: TimeInterval) -> Bool {
        if inCar {
            wasInCar = true
            leftCarAt = nil
            idleSince = nil
            return false
        }
        if wasInCar {
            wasInCar = false
            leftCarAt = now
        }
        if let leftCarAt, now - leftCarAt >= Self.afterCarTimeout {
            return true
        }
        if isPlaying {
            idleSince = nil
            return false
        }
        let since = idleSince ?? now
        idleSince = since
        return now - since >= Self.idleTimeout
    }
}
