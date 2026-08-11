import Foundation
import UserNotifications

enum LocalNotificationPreference: String, CaseIterable, Sendable {
    case sharedItemAdded
    case sharedItemRemoved
    case automaticSyncItemAdded
    case automaticSyncStatusChanged
}

enum LocalNotificationPreferences {
    private static let keyPrefix = "notifications.collection."

    static func key(_ preference: LocalNotificationPreference, collectionID: UUID) -> String {
        "\(keyPrefix)\(collectionID.uuidString).\(preference.rawValue)"
    }

    static func isEnabled(_ preference: LocalNotificationPreference, collectionID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: key(preference, collectionID: collectionID))
    }

    static func migrateLegacySettings(to collectionIDs: [UUID]) {
        let defaults = UserDefaults.standard
        let legacyKeys: [(LocalNotificationPreference, String)] = [
            (.sharedItemAdded, "notifications.sharedItemAdded"),
            (.sharedItemRemoved, "notifications.sharedItemRemoved"),
            (.automaticSyncItemAdded, "notifications.automaticSyncItemAdded"),
            (.automaticSyncStatusChanged, "notifications.automaticSyncStatusChanged")
        ]
        guard legacyKeys.contains(where: { defaults.object(forKey: $0.1) != nil }) else { return }

        for collectionID in collectionIDs {
            for (preference, legacyKey) in legacyKeys where defaults.object(forKey: key(preference, collectionID: collectionID)) == nil {
                if defaults.object(forKey: legacyKey) != nil {
                    defaults.set(defaults.bool(forKey: legacyKey), forKey: key(preference, collectionID: collectionID))
                }
            }
        }
        legacyKeys.forEach { defaults.removeObject(forKey: $0.1) }
    }
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
        for change in changes.sharedItemChanges {
            switch change.kind {
            case .added where LocalNotificationPreferences.isEnabled(.sharedItemAdded, collectionID: change.collectionID):
                schedule(
                    title: "Item added",
                    body: "\(change.itemTitle) was added to \(change.collectionName) by another user."
                )
            case .removed where LocalNotificationPreferences.isEnabled(.sharedItemRemoved, collectionID: change.collectionID):
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
        collectionID: UUID,
        collectionName: String,
        addedItems: [String],
        matchedStateChanges: [AutomaticSyncStateChange]
    ) {
        if LocalNotificationPreferences.isEnabled(.automaticSyncItemAdded, collectionID: collectionID) {
            for title in addedItems {
                schedule(title: "Item added by automatic sync", body: "\(title) was added to \(collectionName).")
            }
        }
        if LocalNotificationPreferences.isEnabled(.automaticSyncStatusChanged, collectionID: collectionID) {
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
