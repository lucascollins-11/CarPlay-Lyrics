import Foundation
import UserNotifications

/// When this sideloaded build stops launching. A build signed with a free Apple ID
/// expires after 7 days (a paid developer account: 1 year), and in the car an
/// expired build just looks broken, so the app warns a couple of days ahead.
///
/// The date comes from `embedded.mobileprovision`: a signed (CMS) blob with the
/// provisioning profile's XML property list inside it in plain text. Simulator and
/// App Store builds have no such file, so their status is `.unknown`.
enum BuildExpiry {
    enum Status: Equatable {
        /// No provisioning profile (Simulator, App Store, TestFlight) or it couldn't be read.
        case unknown
        case valid(expires: Date)
        /// Expires within `warningLead`; `daysLeft` is rounded up, so "1" means less than a day.
        case expiringSoon(expires: Date, daysLeft: Int)
        case expired(on: Date)
    }

    static let warningLead: TimeInterval = 2 * 24 * 3600

    /// The expiry status of the running app.
    static func current(bundle: Bundle = .main, now: Date = Date()) -> Status {
        status(expiration: expirationDate(bundle: bundle), now: now)
    }

    static func expirationDate(bundle: Bundle = .main) -> Date? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return expirationDate(fromProfile: data)
    }

    /// Reads `ExpirationDate` from the property list embedded in a provisioning profile.
    static func expirationDate(fromProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound],
                                                                      options: [], format: nil),
              let dictionary = plist as? [String: Any]
        else { return nil }
        return dictionary["ExpirationDate"] as? Date
    }

    static func status(expiration: Date?, now: Date) -> Status {
        guard let expiration else { return .unknown }
        let remaining = expiration.timeIntervalSince(now)
        if remaining <= 0 { return .expired(on: expiration) }
        if remaining <= warningLead {
            return .expiringSoon(expires: expiration, daysLeft: Int((remaining / (24 * 3600)).rounded(.up)))
        }
        return .valid(expires: expiration)
    }
}

extension BuildExpiry.Status {
    /// What to tell the user, or nil while there is nothing to warn about.
    var warning: String? {
        switch self {
        case .unknown, .valid: return nil
        case .expiringSoon(_, let daysLeft):
            return daysLeft <= 1
                ? "This build of Lyrics stops opening within a day. Reinstall it (Sideloadly or Xcode) before your next drive."
                : "This build of Lyrics stops opening in \(daysLeft) days. Reinstall it (Sideloadly or Xcode) before then."
        case .expired:
            return "This build of Lyrics has expired. Reinstall it with Sideloadly or Xcode."
        }
    }

    var expiryDate: Date? {
        switch self {
        case .unknown: return nil
        case .valid(let date), .expiringSoon(let date, _), .expired(let date): return date
        }
    }
}


/// A local notification about a day before the build expires, so it isn't found out in the car.
/// Re-scheduled on every launch (a reinstall moves the date); permission is asked when Drive mode
/// first starts, not at launch.
enum BuildExpiryReminder {
    static let identifier = "buildExpiry"
    static let lead: TimeInterval = 24 * 3600

    static func reschedule(status: BuildExpiry.Status = BuildExpiry.current(), askIfNeeded: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard let expires = status.expiryDate else { return }
        let fireAt = expires.addingTimeInterval(-lead)
        guard fireAt > Date() else { return }
        Task {
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined, askIfNeeded {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Lyrics expires tomorrow"
            content.body = "Reinstall it (Sideloadly or Xcode) so it still opens in the car."
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }
}
