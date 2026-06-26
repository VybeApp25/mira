import UserNotifications
import AppKit

// Schedules and cancels macOS local notifications for clipboard reminders.
// When a reminder fires, the notification body shows the clip preview and
// clicking it posts .miraShowLabsClipboard so the Labs tab opens to that item.

final class ClipReminderService: NSObject {
    static let shared = ClipReminderService()
    static let notifCategoryID = "CLIP_REMINDER"
    static let clipIDKey       = "clipID"

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(
            identifier: "OPEN_CLIP",
            title: "Open in Labs",
            options: .foreground
        )
        let cat = UNNotificationCategory(
            identifier: Self.notifCategoryID,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([cat])
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func schedule(item: ClipboardItem, at date: Date) {
        guard date > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Clip Reminder"
        content.body  = item.displayTitle
        content.sound = .default
        content.categoryIdentifier = Self.notifCategoryID
        content.userInfo = [Self.clipIDKey: item.id.uuidString]

        let comps   = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req     = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(req)
    }

    func cancel(itemID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [itemID.uuidString]
        )
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension ClipReminderService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let idStr = response.notification.request.content.userInfo[Self.clipIDKey] as? String
        let clipID = idStr.flatMap { UUID(uuidString: $0) }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .miraShowLabsClipboard,
                object: clipID
            )
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let miraShowLabsClipboard = Notification.Name("miraShowLabsClipboard")
}
