import Foundation
import MnemosyneCore
@preconcurrency import UserNotifications

/// Уведомления: «Начинается «…» — записать?» и «Похоже, встреча закончилась».
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    enum Action { case record(eventId: String), stop, snooze, open(path: String) }

    var onAction: ((Action) -> Void)?
    private let center = UNUserNotificationCenter.current()

    private enum ID {
        static let startCategory = "start"
        static let endCategory = "end"
        static let readyCategory = "ready"
        static let record = "record"
        static let stop = "stop"
        static let snooze = "snooze"
        static let endRequest = "end-reminder"
    }

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ID.startCategory,
                                   actions: [UNNotificationAction(identifier: ID.record, title: String(localized: "Записать"))],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: ID.endCategory,
                                   actions: [UNNotificationAction(identifier: ID.stop, title: String(localized: "Остановить")),
                                             UNNotificationAction(identifier: ID.snooze, title: String(localized: "Ещё 15 минут"))],
                                   intentIdentifiers: []),
        ])
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func postStart(_ event: CalendarEventInfo) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Начинается «\(event.title)»")
        content.body = String(localized: "Записать встречу?")
        content.categoryIdentifier = ID.startCategory
        content.userInfo = ["eventId": event.id]
        post(id: "start-\(event.id)", content)
    }

    func postEnd(title: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Похоже, встреча закончилась")
        content.body = String(localized: "«\(title)» всё ещё записывается")
        content.categoryIdentifier = ID.endCategory
        post(id: ID.endRequest, content)
    }

    func postTranscriptReady(title: String, file: URL) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Транскрипт готов")
        content.body = String(localized: "«\(title)»")
        content.categoryIdentifier = ID.readyCategory
        content.userInfo = ["path": file.path]
        post(id: "ready-\(file.path.hashValue)", content)
    }

    func postSummaryReady(title: String, file: URL) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Саммари готово")
        content.body = String(localized: "«\(title)»")
        content.categoryIdentifier = ID.readyCategory
        content.userInfo = ["path": file.path]
        post(id: "summary-\(file.path.hashValue)", content)
    }

    /// Одно уведомление на попадание в лимит: «повторим в 15:10, транскрипт готов».
    func postLimit(title: String, retryAt: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Лимит подписки Claude")
        content.body = String(localized: "Анализ «\(title)» повторим в \(retryAt). Транскрипт уже готов.")
        post(id: "limit", content)
    }

    func postAnalysisFailed(title: String, error: String, transcript: URL?) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Анализ «\(title)» не удался")
        content.body = error
        if let transcript {
            content.categoryIdentifier = ID.readyCategory
            content.userInfo = ["path": transcript.path]
        }
        post(id: "analysis-failed-\(title.hashValue)", content)
    }

    func postProcessingFailed(title: String, error: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Не удалось обработать «\(title)»")
        content.body = error
        post(id: "failed-\(title.hashValue)", content)
    }

    func removeEndReminder() {
        center.removeDeliveredNotifications(withIdentifiers: [ID.endRequest])
    }

    private func post(id: String, _ content: UNNotificationContent) {
        // Колбэк add(_:withCompletionHandler:) приходит на фоновой очереди. Замыкание,
        // объявленное в @MainActor-классе, наследует изоляцию, и Swift 6 роняет
        // приложение проверкой очереди. Поэтому async-вариант без колбэка.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let center = self.center
        Task.detached {
            do { try await center.add(request) } catch {
                Log.app.error("notification: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let category = response.notification.request.content.categoryIdentifier
        let eventId = response.notification.request.content.userInfo["eventId"] as? String
        let path = response.notification.request.content.userInfo["path"] as? String
        let actionId = response.actionIdentifier
        await MainActor.run {
            let action: Action? = switch (category, actionId) {
            // Клик по самому уведомлению о начале тоже запускает запись.
            case (ID.startCategory, ID.record), (ID.startCategory, UNNotificationDefaultActionIdentifier):
                eventId.map { .record(eventId: $0) }
            case (ID.endCategory, ID.stop): .stop
            case (ID.endCategory, ID.snooze): .snooze
            case (ID.readyCategory, UNNotificationDefaultActionIdentifier): path.map { .open(path: $0) }
            default: nil
            }
            if let action { onAction?(action) }
        }
    }
}
