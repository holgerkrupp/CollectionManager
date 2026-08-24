import SwiftUI
import SwiftData
import CloudKit
#if os(iOS)
import UIKit

final class CloudShareAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = CloudShareSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        CloudShareInvitationInbox.shared.receive(metadata)
    }
}

final class CloudShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            CloudShareInvitationInbox.shared.receive(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        CloudShareInvitationInbox.shared.receive(metadata)
    }
}
#elseif os(macOS)
import AppKit

final class CloudShareAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        CloudShareInvitationInbox.shared.receive(metadata)
    }
}
#endif

@MainActor final class CloudShareInvitationInbox {
    static let shared = CloudShareInvitationInbox()

    private var pending: [CKShare.Metadata] = []
    private var handler: ((CKShare.Metadata) async -> Void)?
    private var isProcessing = false

    func install(handler: @escaping (CKShare.Metadata) async -> Void) {
        self.handler = handler
        processNextIfNeeded()
    }

    func receive(_ metadata: CKShare.Metadata) {
        pending.append(metadata)
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        guard !isProcessing, let handler, !pending.isEmpty else { return }
        isProcessing = true
        let metadata = pending.removeFirst()
        Task {
            await handler(metadata)
            isProcessing = false
            processNextIfNeeded()
        }
    }
}

@main struct CollectionManagerApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CloudShareAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(CloudShareAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
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
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    store.configure(context: container.mainContext, container: container)
                    CloudShareInvitationInbox.shared.install { metadata in
                        await store.acceptShare(metadata: metadata)
                    }
                    store.loadCollections()
                    WebSyncScheduler.schedule(context: container.mainContext)
                    // Keep launch local and responsive. Sync starts after the
                    // first frame and is skipped when the process has no
                    // CloudKit entitlement (for example an unsigned simulator build).
                    await Task.yield()
                    await store.loadSelectedCollectionInBackground()
                    await store.syncCollections()

                    // CloudKit collaboration changes can arrive while the app
                    // remains open. Refresh periodically while active so edits
                    // from other participants appear without a relaunch.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(30))
                        guard !Task.isCancelled else { return }
                        await store.syncCollections()
                    }
                }
                .onOpenURL { url in Task { await store.acceptShare(from: url) } }
        }
        .modelContainer(container)
        #if os(macOS)
        Settings {
            SettingsView()
                .environment(store)
        }

        // Collection settings get a real, resizable window rather than a sheet:
        // the statuses and metadata editors need room, and keying the group by
        // collection lets several collections be configured side by side.
        WindowGroup(id: CollectionSettingsWindow.id, for: UUID.self) { $collectionID in
            CollectionSettingsWindowView(collectionID: collectionID)
                .environment(store)
        }
        .modelContainer(container)
        .defaultSize(width: 940, height: 600)
        .windowResizability(.contentMinSize)
        #endif
    }
}
