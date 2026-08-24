import Foundation
#if os(iOS)
import BackgroundTasks
#endif
import SwiftData

enum WebSyncScheduler {
    static let identifier = "de.holgerkrupp.CollectionManager.web-sync"

    static func register(container: ModelContainer) {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task { @MainActor in
                let context = ModelContext(container)
                let configs = enabledSyncs(in: context).filter { isDue($0) }
                var success = !Task.isCancelled

                for config in configs where !Task.isCancelled {
                    let result = await HTMLSyncCoordinator(context: context).sync(config)
                    if let collectionID = result.collectionID {
                        LocalNotificationService.shared.scheduleAutomaticSyncNotifications(collectionID: collectionID, collectionName: result.collectionName, addedItems: result.addedItems, matchedStateChanges: result.matchedStateChanges)
                    }
                    if result.error != nil { success = false }
                }
                task.setTaskCompleted(success: success && !Task.isCancelled)
                schedule(context: context)
            }
            task.expirationHandler = { work.cancel() }
        }
        #endif
        // macOS has no BGTaskScheduler equivalent. The app's foreground sync
        // loop (started while the scene is active) keeps web sources current
        // instead, so there is nothing to register here.
    }

    /// Submits one request for the source that is due next. iOS decides the
    /// actual launch time, so `earliestBeginDate` is deliberately a lower bound.
    @MainActor static func schedule(context: ModelContext) {
        #if os(iOS)
        let syncs = enabledSyncs(in: context)
        guard let nextDate = syncs.map({ nextDueDate(for: $0) }).min() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }

        // The scheduler accepts only one pending request per identifier. Replace
        // the old request so a configuration edit cannot leave a stale schedule.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = nextDate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // There is no useful recovery action here: the app resubmits when it
            // becomes active, and iOS may temporarily reject a request by policy.
        }
        #endif
    }

    @MainActor private static func enabledSyncs(in context: ModelContext) -> [WebSyncRecord] {
        (try? context.fetch(FetchDescriptor<WebSyncRecord>(predicate: #Predicate { $0.enabled }))) ?? []
    }

    private static func isDue(_ sync: WebSyncRecord, now: Date = .now) -> Bool {
        nextDueDate(for: sync) <= now
    }

    private static func nextDueDate(for sync: WebSyncRecord) -> Date {
        guard let lastSyncAt = sync.lastSyncAt else { return .now }
        return lastSyncAt.addingTimeInterval(TimeInterval(max(sync.intervalMinutes, 15) * 60))
    }
}
