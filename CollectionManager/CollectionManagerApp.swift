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
                    store.configure(context: container.mainContext)
                    store.load()
                    WebSyncScheduler.schedule()
                    // Give SwiftUI a chance to commit the first local frame.
                    await Task.yield()
                    await store.syncCollections()
                }
                .onOpenURL { url in Task { await store.acceptShare(from: url) } }
        }
        .modelContainer(container)
    }
}
