import AppKit
import UserNotifications

/// Says when long work ends while the user is in another app. Permission is asked when such work starts,
/// while they are here to answer.
@MainActor
enum Notifier {
    static func ask() {
        guard !FreedownApp.isTesting else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// Only when the app is in the background: otherwise the window already shows it
    static func post(_ title: String, _ body: String) {
        guard !FreedownApp.isTesting, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
    }
}
