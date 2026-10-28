import SwiftUI
import SwiftData
import CloudKit
import CollaborationCore
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

    nonisolated func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // UIKit's payload is not Sendable. Keep it on the caller's executor;
        // only the payload-free refresh signal crosses to the UI actor.
        await MainActor.run {
            NotificationCenter.default.post(name: .collectionManagerCloudKitDidChange, object: nil)
        }
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
    private var handler: ((CKShare.Metadata) async -> Bool)?
    private var isProcessing = false
    private var storageKey: String { "collaboration.pendingInvitations." + CloudKitSharingService.environment.rawValue }

    private init() {
        let key = "collaboration.pendingInvitations." + CloudKitSharingService.environment.rawValue
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: CKShare.Metadata.self, from: data) {
            pending = decoded
        }
    }

    func install(handler: @escaping (CKShare.Metadata) async -> Bool) {
        self.handler = handler
        processNextIfNeeded()
    }

    func receive(_ metadata: CKShare.Metadata) {
        guard metadata.containerIdentifier == CloudKitSharingService.containerIdentifier else { return }
        if !pending.contains(where: { $0.share.recordID == metadata.share.recordID }) {
            pending.append(metadata)
            persist()
        }
        processNextIfNeeded()
    }

    private func persist() {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: pending, requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            // Preserve in-memory delivery and the prior durable queue for retry.
            Logger(subsystem: "de.holgerkrupp.CollectionManager", category: "invitations").error("Invitation queue could not be saved")
        }
    }

    private func processNextIfNeeded() {
        guard !isProcessing, let handler, let metadata = pending.first else { return }
        isProcessing = true
        Task {
            let accepted = await handler(metadata)
            if accepted {
                pending.removeAll { $0.share.recordID == metadata.share.recordID }
                persist()
            }
            isProcessing = false
            // A failed delivery stays queued. Foreground activation or another
            // delivery retries it, without an unbounded network retry loop.
            if accepted { processNextIfNeeded() }
        }
    }
}

private struct IsolatedTestLayout: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-testing-rtl-large-text") {
            content.environment(\.layoutDirection, .rightToLeft)
                .environment(\.dynamicTypeSize, .accessibility5)
                .environment(\.locale, Locale(identifier: "ar"))
        } else { content }
        #else
        content
        #endif
    }
}

@main struct CollectionManagerApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CloudShareAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(CloudShareAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var oneTimeRecoveryComplete = false
    @State private var oneTimeRecoveryError: String?
    @State private var recoveryAttempt = 0
    private var recoveryRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--recover-legacy-default-store-once") ||
        ProcessInfo.processInfo.arguments.contains("--resume-after-legacy-recovery-review")
    }
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
        let appStore = store
        WindowGroup {
            Group {
                if let container {
                    if recoveryRequested && !oneTimeRecoveryComplete {
                        VStack(spacing: 16) {
                            Text("Recovering your older library").font(.title2)
                            if let oneTimeRecoveryError {
                                Text(oneTimeRecoveryError)
                                Button("Retry") { recoveryAttempt += 1 }
                            } else { ProgressView("Preserving both stores and restoring missing records…") }
                        }
                        .padding()
                        .task(id: recoveryAttempt) {
                            oneTimeRecoveryError = nil
                            do {
                                if ProcessInfo.processInfo.arguments.contains("--recover-legacy-default-store-once") {
                                    let result = try await store.restoreOldDefaultStoreOnce()
                                    print("CM_ONE_TIME_RECOVERY imported=\(result.importedItems) source=\(result.items) history=\(result.events) queued=\(result.pendingChanges)")
                                } else { try await store.resumeCloudAfterOneTimeRecovery() }
                                oneTimeRecoveryComplete = true
                            } catch { oneTimeRecoveryError = error.localizedDescription }
                        }
                    } else {
                    RootView()
                        .environment(appStore)
                        .modifier(IsolatedTestLayout())
                        .task(id: scenePhase) {
                            guard scenePhase == .active else { return }
                            if Self.isRunningTests { store.load(); return }
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
                        .onOpenURL { [store] url in Task { await store.acceptShare(from: url) } }
                    }
                } else if let startupFailure {
                    StoreRecoveryView(failure: startupFailure, retry: retryStore, selectEnvironment: confirmStoreEnvironment)
                } else {
                    ProgressView("Opening your library…")
                }
            }
        }
        #if os(macOS)
        Settings {
            if container != nil {
                SettingsView().environment(appStore)
            } else if let startupFailure {
                StoreRecoveryView(failure: startupFailure, retry: retryStore, selectEnvironment: confirmStoreEnvironment)
            }
        }

        // Collection settings get a real, resizable window rather than a sheet:
        // the statuses and metadata editors need room, and keying the group by
        // collection lets several collections be configured side by side.
        WindowGroup(id: CollectionSettingsWindow.id, for: UUID.self) { $collectionID in
            CollectionSettingsWindowView(collectionID: collectionID)
                .environment(appStore)
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

    private func retryStore() { openStore(allowEnvironmentSelection: false) }
    private func confirmStoreEnvironment() { openStore(allowEnvironmentSelection: true) }
    private func openStore(allowEnvironmentSelection: Bool) {
        do {
            let openedContainer = try PersistentStoreBootstrap.makeContainer(allowEnvironmentSelection: allowEnvironmentSelection)
            container = openedContainer
            startupFailure = nil
            store.configure(context: openedContainer.mainContext, container: openedContainer)
            if !Self.isRunningTests { WebSyncScheduler.register(container: openedContainer) }
            let configuredStore = store
            AppDependencyManager.shared.add(dependency: configuredStore)
        } catch {
            startupFailure = PersistentStoreBootstrap.failure(for: error)
        }
    }
}
