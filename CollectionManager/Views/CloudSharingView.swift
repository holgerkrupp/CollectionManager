import SwiftUI
import CloudKit

struct CloudSharingView: View {
    let collection: CollectionModel; @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss; @State private var share: CKShare?; @State private var errorMessage: String?
    var body: some View { Group { if let share { CloudSharingControllerView(share: share, onDismiss: dismiss) } else if !collection.role.canEdit { ContentUnavailableView("View-only collection", systemImage: "eye", description: Text("You can review this collection, but only an owner or editor can change it.")) } else { ProgressView("Preparing secure share…").task { do { share = try await CloudKitSharingService().makeShare(for: collection, items: store.items) } catch { errorMessage = "iCloud sharing is not available yet. Configure the app’s iCloud container and sign in to iCloud." } }.alert("Sharing unavailable", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { dismiss() } } message: { Text(errorMessage ?? "") } } } }
}

struct CloudSharingControllerView: UIViewControllerRepresentable {
    let share: CKShare; let onDismiss: DismissAction
    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }
    func makeUIViewController(context: Context) -> UICloudSharingController { let controller = CloudKitSharingService().controller(for: share); controller.delegate = context.coordinator; return controller }
    func updateUIViewController(_ controller: UICloudSharingController, context: Context) { }
    final class Coordinator: NSObject, UICloudSharingControllerDelegate { let onDismiss: DismissAction; init(onDismiss: DismissAction) { self.onDismiss = onDismiss }; func cloudSharingController(_ c: UICloudSharingController, failedToSaveShareWithError error: Error) { }; func itemTitle(for c: UICloudSharingController) -> String? { c.share?.recordID.recordName }; func cloudSharingControllerDidSaveShare(_ c: UICloudSharingController) { }; func cloudSharingControllerDidStopSharing(_ c: UICloudSharingController) { onDismiss() } }
}
