import Foundation
import UserNotifications

enum LocalNotificationPreferences {
    static let sharedItemAdded = "notifications.sharedItemAdded"
    static let sharedItemRemoved = "notifications.sharedItemRemoved"
    static let automaticSyncItemAdded = "notifications.automaticSyncItemAdded"
    static let automaticSyncStatusChanged = "notifications.automaticSyncStatusChanged"
}

struct AutomaticSyncStateChange: Sendable {
    let title: String
    let newState: ItemState
}

struct SharedCollectionItemChange: Sendable {
    enum Kind: Sendable {
        case added
        case removed
    }

    let collectionID: UUID
    let collectionName: String
    let itemTitle: String
    let kind: Kind
}

struct CloudMergeNotificationChanges: Sendable {
    var sharedItemChanges: [SharedCollectionItemChange] = []
}

@MainActor
final class LocalNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotificationService()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func scheduleSharedChanges(_ changes: CloudMergeNotificationChanges) {
        let defaults = UserDefaults.standard
        for change in changes.sharedItemChanges {
            switch change.kind {
            case .added where defaults.bool(forKey: LocalNotificationPreferences.sharedItemAdded):
                schedule(
                    title: "Item added",
                    body: "\(change.itemTitle) was added to \(change.collectionName) by another user."
                )
            case .removed where defaults.bool(forKey: LocalNotificationPreferences.sharedItemRemoved):
                schedule(
                    title: "Item removed",
                    body: "\(change.itemTitle) was removed from \(change.collectionName) by another user."
                )
            default:
                break
            }
        }
    }

    func scheduleAutomaticSyncNotifications(
        collectionName: String,
        addedItems: [String],
        matchedStateChanges: [AutomaticSyncStateChange]
    ) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: LocalNotificationPreferences.automaticSyncItemAdded) {
            for title in addedItems {
                schedule(title: "Item added by automatic sync", body: "\(title) was added to \(collectionName).")
            }
        }
        if defaults.bool(forKey: LocalNotificationPreferences.automaticSyncStatusChanged) {
            for change in matchedStateChanges {
                schedule(
                    title: "Item status changed by automatic sync",
                    body: "\(change.title) in \(collectionName) is now \(change.newState.label)."
                )
            }
        }
    }

    func userEnabledNotification(_ enabled: Bool) {
        guard enabled else { return }
        Task { await requestAuthorization() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func schedule(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        Task { try? await center.add(request) }
    }
}
