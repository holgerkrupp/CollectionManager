import SwiftUI
import CloudKit
import CollaborationUI
import CollaborationCore
import CollaborationCloudKit

struct CloudSharingView: View {
    let collection: CollectionModel
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var share: CKShare?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var showingLeaveConfirmation = false
    @State private var showingManagement = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let session = store.sharingSession {
                    if isLoading { ProgressView("Checking sharing access…") }
                    else if session.canInvite(collectionID: collection.id) {
                        CloudKitShareLink(
                            rootID: collection.id.uuidString,
                            title: collection.name,
                            container: session.backend.cloudKitContainer,
                            sharing: session.backend
                        ) { Label("Invite people", systemImage: "person.badge.plus") }
                        .buttonStyle(.borderedProminent)
                        if let share, session.access[collection.id]?.canManageShare == true {
                            #if os(iOS)
                            Button("Manage sharing") { showingManagement = true }
                            #elseif os(macOS)
                            NativeCollectionSharingButton(share: share, collection: collection, session: session) { error in
                                if let error { errorMessage = CollectionSharingSession.message(for: error) }
                                Task { await refresh(session) }
                            }
                            .frame(height: 32)
                            #endif
                        }
                        Text("Apple’s sharing controls manage invitations and permissions.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if errorMessage == nil {
                        ContentUnavailableView("Sharing managed by the owner", systemImage: "person.crop.circle.badge.checkmark", description: Text("Ask the owner to invite people or change sharing permissions."))
                        if share != nil {
                            Button("Leave shared collection", role: .destructive) { showingLeaveConfirmation = true }
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("Retry") { Task { await refresh(session) } }
                    }
                    if let status = session.invitationStatus { Text(status).font(.footnote) }
                    if let failure = session.invitationFailure {
                        Text(failure).font(.footnote).foregroundStyle(.secondary)
                        Button("Retry invitation") { Task { await session.retryInvitations() } }
                    }
                } else {
                    ContentUnavailableView("Sharing is not ready", systemImage: "icloud.slash", description: Text("Open your library with an available iCloud account, then try again."))
                }
            }
            .padding(24)
            .frame(minWidth: 280, minHeight: 180)
            .navigationTitle("Share collection")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                guard let session = store.sharingSession else { isLoading = false; return }
                await refresh(session)
            }
            .confirmationDialog("Leave this shared collection?", isPresented: $showingLeaveConfirmation, titleVisibility: .visible) {
                Button("Leave shared collection", role: .destructive) {
                    guard let session = store.sharingSession else { return }
                    Task {
                        do { try await session.leave(collectionID: collection.id); await store.syncCollections(); dismiss() }
                        catch { errorMessage = CollectionSharingSession.message(for: error) }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Future shared updates stop. Local records and queued changes are kept safely as read-only data; other collections are unaffected.") }
            #if os(iOS)
            .sheet(isPresented: $showingManagement) {
                if let share, let session = store.sharingSession,
                   session.access[collection.id]?.canManageShare == true {
                    NativeCloudSharingController(
                        share: share,
                        title: collection.name,
                        rootID: collection.id.uuidString,
                        sharing: session.backend,
                        onShareChanged: { Task { await refresh(session) } },
                        onStopSharing: { showingManagement = false; Task { await refresh(session) } },
                        onFailure: { errorMessage = CollectionSharingSession.message(for: $0) }
                    )
                }
            }
            #endif
        }
    }

    private func refresh(_ session: CollectionSharingSession) async {
        isLoading = true
        errorMessage = nil
        do { share = try await session.refresh(collectionID: collection.id) }
        catch { errorMessage = CollectionSharingSession.message(for: error) }
        isLoading = false
    }
}

#if os(macOS)
import AppKit

/// The click presents the kit's CloudKit-aware native service. Merely showing
/// the sheet does not create a share or start an invitation.
private struct NativeCollectionSharingButton: NSViewRepresentable {
    let share: CKShare
    let collection: CollectionModel
    let session: CollectionSharingSession
    let onCompletion: (Error?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: String(localized: "Manage sharing"), target: context.coordinator, action: #selector(Coordinator.present(_:)))
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(String(localized: "Manage sharing"))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.parent = self }

    @MainActor
    final class Coordinator: NSObject {
        var parent: NativeCollectionSharingButton
        let presenter = NativeMacCloudSharingPresenter()
        init(_ parent: NativeCollectionSharingButton) { self.parent = parent }

        @objc func present(_ sender: NSButton) {
            guard parent.session.access[parent.collection.id]?.canManageShare == true else { return }
            presenter.onCompleted = parent.onCompletion
            presenter.present(share: parent.share, rootID: parent.collection.id.uuidString, sharing: parent.session.backend, anchoredTo: sender)
        }
    }
}
#endif
