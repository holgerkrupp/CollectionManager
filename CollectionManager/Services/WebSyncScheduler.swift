import BackgroundTasks
import SwiftData

enum WebSyncScheduler {
    static let identifier = "de.holgerkrupp.CollectionManager.web-sync"
    static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task { @MainActor in
                let context = ModelContext(container); let configs = (try? context.fetch(FetchDescriptor<WebSyncRecord>(predicate: #Predicate { $0.enabled }))) ?? []; var success = true
                for config in configs {
                    let result = await HTMLSyncCoordinator(context: context).sync(config)
                    if let collectionID = result.collectionID {
                        LocalNotificationService.shared.scheduleAutomaticSyncNotifications(collectionID: collectionID, collectionName: result.collectionName, addedItems: result.addedItems, matchedStateChanges: result.matchedStateChanges)
                    }
                    if result.error != nil { success = false }
                }
                task.setTaskCompleted(success: success); schedule()
            }
        }
    }
    static func schedule() { let request = BGAppRefreshTaskRequest(identifier: identifier); let minutes = UserDefaults.standard.object(forKey: "websync.minimumIntervalMinutes") as? Double ?? 360; request.earliestBeginDate = Date(timeIntervalSinceNow: max(minutes, 15) * 60); try? BGTaskScheduler.shared.submit(request) }
}
