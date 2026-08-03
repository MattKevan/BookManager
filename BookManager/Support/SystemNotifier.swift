import BookManagerCore
import Foundation
import UserNotifications

/// Presents banners while the app is frontmost (macOS suppresses foreground
/// notifications by default). Retained for the process by `shared`; assigned
/// to the notification center before every post (idempotent).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Posts completion feedback as standard macOS system notifications.
/// Authorization is requested lazily on first use; every post returns false
/// when notifications are not authorized so callers can fall back to their
/// existing report sheet.
enum SystemNotifier {
    /// Resolves notification authorization; true when notifications can be
    /// posted (authorized / provisional / ephemeral). Idempotent after the
    /// first call; never throws.
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// Posts a notification; returns false when authorization is missing or
    /// posting failed (caller falls back to a sheet).
    @discardableResult
    static func post(title: String, body: String) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    /// "Import complete" summary with the failed items listed (truncated).
    static func postImportCompletion(report: ImportReport) async -> Bool {
        var body = report.summary
        let failed = report.failed
        if !failed.isEmpty {
            let names = failed.prefix(4).map { $0.sourceURL.lastPathComponent }
            body += " — failed: " + truncated(names, extra: failed.count - names.count)
        }
        return await post(title: "Import complete", body: body)
    }

    /// "Sent to device" summary with the unsent items listed (truncated).
    static func postSendCompletion(report: SendReport) async -> Bool {
        var body = report.summary
        let issues = report.noCompatible + report.failed
        if !issues.isEmpty {
            let names = issues.prefix(4).map(\.title)
            body += " — not sent: " + truncated(names, extra: issues.count - names.count)
        }
        return await post(title: "Sent to device", body: body)
    }

    private static func truncated(_ names: [String], extra: Int) -> String {
        var joined = names.joined(separator: ", ")
        if extra > 0 {
            joined += "… and \(extra) more"
        }
        return joined
    }
}
