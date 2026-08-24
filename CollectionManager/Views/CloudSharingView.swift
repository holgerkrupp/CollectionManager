import SwiftUI
import CloudKit

struct CloudSharingView: View {
    let collection: CollectionModel; @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss; @State private var share: CKShare?; @State private var errorMessage: String?
    var body: some View { Group { if let share { CloudSharingControllerView(share: share, onDismiss: dismiss) { Task { await store.syncCollections() } } } else if !collection.role.canEdit { ContentUnavailableView("View-only collection", systemImage: "eye", description: Text("You can review this collection, but only an owner or editor can change it.")) } else { ProgressView("Preparing secure share…").task { do { share = try await CloudKitSharingService().makeShare(for: collection, items: store.items) } catch { errorMessage = sharingMessage(for: error) } }.alert("Sharing unavailable", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { dismiss() } } message: { Text(errorMessage ?? "") } } } }

    private func sharingMessage(for error: Error) -> String {
        if let error = error as? SharingError { return error.localizedDescription }
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .notAuthenticated:
            return SharingError.noAccount.localizedDescription
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return SharingError.temporarilyUnavailable.localizedDescription
        case .quotaExceeded:
            return "Your iCloud storage is full. Free some space and try sharing again."
        case .permissionFailure, .badContainer:
            return "Collection Manager does not have access to its iCloud container. Rebuild the app with the iCloud capability enabled. (CloudKit \(error.errorCode))"
        default:
            return "iCloud could not prepare this collection for sharing. \(error.localizedDescription) (CloudKit \(error.errorCode))"
        }
    }
}

#if os(iOS)
struct CloudSharingControllerView: UIViewControllerRepresentable {
    let share: CKShare; let onDismiss: DismissAction; let onShareChanged: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss, onShareChanged: onShareChanged) }
    func makeUIViewController(context: Context) -> UICloudSharingController { let controller = CloudKitSharingService().controller(for: share); controller.delegate = context.coordinator; return controller }
    func updateUIViewController(_ controller: UICloudSharingController, context: Context) { }
    final class Coordinator: NSObject, UICloudSharingControllerDelegate { let onDismiss: DismissAction; let onShareChanged: () -> Void; init(onDismiss: DismissAction, onShareChanged: @escaping () -> Void) { self.onDismiss = onDismiss; self.onShareChanged = onShareChanged }; func cloudSharingController(_ c: UICloudSharingController, failedToSaveShareWithError error: Error) { }; func itemTitle(for c: UICloudSharingController) -> String? { c.share?.recordID.recordName }; func cloudSharingControllerDidSaveShare(_ c: UICloudSharingController) { onShareChanged() }; func cloudSharingControllerDidStopSharing(_ c: UICloudSharingController) { onShareChanged(); onDismiss() } }
}
#elseif os(macOS)
import AppKit

/// macOS has no direct equivalent of UICloudSharingController. Present the
/// system share sheet (NSSharingServicePicker) with the CKShare, which lets
/// the user send the invitation the same way as any other shared item.
struct CloudSharingControllerView: NSViewControllerRepresentable {
    let share: CKShare; let onDismiss: DismissAction; let onShareChanged: () -> Void

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = CloudSharingHostController()
        controller.share = share
        controller.onShareChanged = onShareChanged
        controller.onDismiss = onDismiss
        return controller
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) { }

    final class CloudSharingHostController: NSViewController {
        var share: CKShare?
        var onShareChanged: (() -> Void)?
        var onDismiss: DismissAction?
        private var didPresent = false

        override func loadView() { view = NSView() }

        override func viewDidAppear() {
            super.viewDidAppear()
            guard !didPresent, let share else { return }
            didPresent = true
            let picker = NSSharingServicePicker(items: [share])
            picker.delegate = self
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                picker.show(relativeTo: .zero, of: self.view, preferredEdge: .minY)
            }
        }
    }
}

extension CloudSharingControllerView.CloudSharingHostController: NSSharingServicePickerDelegate {
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        onShareChanged?()
        onDismiss?()
    }
}
#endif
