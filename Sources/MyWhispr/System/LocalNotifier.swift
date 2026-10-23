import Foundation
import UserNotifications

/// Formats the short banner shown when the local model attaches tags.
enum MeetingTagAssignmentNotice: Equatable, Sendable {
    static func body(meetingTitle: String, tagNames: [String]) -> String {
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty ? "Untitled meeting" : title
        let tags = tagNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tags.isEmpty else {
            return "“\(displayTitle)” received tags."
        }
        return "“\(displayTitle)” → \(tags.joined(separator: ", "))"
    }
}

/// Delivers local macOS Notification Center banners from the menu-bar app.
///
/// `UNUserNotificationCenter` requires a real app identity. Test hosts and CLI
/// helpers must not touch it, or Foundation aborts the process.
@MainActor
final class LocalNotifier {
    static let shared = LocalNotifier()

    func notifyTagsAssigned(meetingTitle: String, tagNames: [String]) {
        guard !tagNames.isEmpty else { return }
        let body = MeetingTagAssignmentNotice.body(
            meetingTitle: meetingTitle,
            tagNames: tagNames
        )
        Task { await deliver(title: "Tags assigned", body: body) }
    }

    private func deliver(title: String, body: String) async {
        guard Bundle.main.bundleIdentifier == "app.mywhispr.mac" else { return }
        let center = UNUserNotificationCenter.current()

        let granted = await ensureAuthorization(center)
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "tag-assignment-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    private func ensureAuthorization(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }
}
