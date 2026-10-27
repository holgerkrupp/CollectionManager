import SwiftUI
import SwiftData
import CloudKit
import AppIntents
import OSLog
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

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        NotificationCenter.default.post(name: .collectionManagerCloudKitDidChange, object: nil)
        return .newData
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

extension Notification.Name {
    static let collectionManagerCloudKitDidChange = Notification.Name("CollectionManager.cloudKitDidChange")
}

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
    @State private var container: ModelContainer?
    @State private var startupFailure: StoreStartupFailure?
    @State private var store: AppStore
    init() {
        if !Self.isRunningTests { AppTips.configure() }
        let openedContainer: ModelContainer?
        let failure: StoreStartupFailure?
        do {
            openedContainer = try PersistentStoreBootstrap.makeContainer()
            failure = nil
        } catch {
            openedContainer = nil
            failure = PersistentStoreBootstrap.failure(for: error)
        }
        _container = State(initialValue: openedContainer)
        _startupFailure = State(initialValue: failure)

        // App Intents can run in the background before any window exists,
        // so the store is configured here instead of when a scene activates.
        let store = AppStore()
        if let openedContainer {
            store.configure(context: openedContainer.mainContext, container: openedContainer)
            if !Self.isRunningTests { WebSyncScheduler.register(container: openedContainer) }
        }
        _store = State(initialValue: store)
        if openedContainer != nil {
            AppDependencyManager.shared.add(dependency: store)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container {
                    RootView()
                        .environment(store)
                        .task(id: scenePhase) {
                            guard scenePhase == .active, !Self.isRunningTests else { return }
                            store.configure(context: container.mainContext, container: container)
                            CloudShareInvitationInbox.shared.install { metadata in
                                await store.acceptShare(metadata: metadata)
                            }
                            store.loadCollections()
                            WebSyncScheduler.schedule(context: container.mainContext)
                            await Task.yield()
                            await store.loadSelectedCollectionInBackground()
                            await store.syncCollections()
                            await store.updateSpotlightIndex()
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .collectionManagerCloudKitDidChange)) { _ in
                            Task { await store.syncCollections() }
                        }
                        .onOpenURL { url in Task { await store.acceptShare(from: url) } }
                } else if let startupFailure {
                    StoreRecoveryView(failure: startupFailure, retry: retryStore)
                } else {
                    ProgressView("Opening your library…")
                }
            }
        }
        #if os(macOS)
        Settings {
            if container != nil {
                SettingsView().environment(store)
            } else if let startupFailure {
                StoreRecoveryView(failure: startupFailure, retry: retryStore)
            }
        }

        // Collection settings get a real, resizable window rather than a sheet:
        // the statuses and metadata editors need room, and keying the group by
        // collection lets several collections be configured side by side.
        WindowGroup(id: CollectionSettingsWindow.id, for: UUID.self) { $collectionID in
            CollectionSettingsWindowView(collectionID: collectionID)
                .environment(store)
        }
        .defaultSize(width: 940, height: 600)
        .windowResizability(.contentMinSize)
        #endif
    }

    private static var isRunningTests: Bool {
        #if DEBUG
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        false
        #endif
    }

    private func retryStore() {
        do {
            let openedContainer = try PersistentStoreBootstrap.makeContainer()
            container = openedContainer
            startupFailure = nil
            store.configure(context: openedContainer.mainContext, container: openedContainer)
            if !Self.isRunningTests { WebSyncScheduler.register(container: openedContainer) }
            AppDependencyManager.shared.add(dependency: store)
        } catch {
            startupFailure = PersistentStoreBootstrap.failure(for: error)
        }
    }
}
