import SwiftUI
import SwiftData

@main struct CollectionManagerApp: App {
    let container: ModelContainer
    @State private var store = AppStore()
    init() {
        let models: Schema = Schema([
            CollectionRecord.self,
            CollectionMemberRecord.self,
            ItemRecord.self,
            ItemRatingRecord.self,
            ItemCommentRecord.self,
            EventRecord.self,
            WebSyncRecord.self,
            SyncMutationRecord.self,
            CloudSyncStateRecord.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: false, cloudKitDatabase: .none)

        // Keep the UI launchable if a local store is temporarily unreadable.
        container = (try? ModelContainer(for: models, configurations: configuration))
            ?? (try? ModelContainer(for: models, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
            ?? Self.unrecoverableContainer()
        WebSyncScheduler.register(container: container)
    }

    private static func unrecoverableContainer() -> ModelContainer {
        fatalError("CollectionManager could not create a SwiftData container.")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task {
                    store.configure(context: container.mainContext, container: container)
                    store.loadCollections()
                    WebSyncScheduler.schedule()
                    // Keep launch local and responsive. Sync starts after the
                    // first frame and is skipped when the process has no
                    // CloudKit entitlement (for example an unsigned simulator build).
                    await Task.yield()
                    await store.loadSelectedCollectionInBackground()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    await store.syncCollections()
                }
                .onOpenURL { url in Task { await store.acceptShare(from: url) } }
        }
        .modelContainer(container)
    }
}
