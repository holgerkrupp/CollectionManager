import SwiftUI

/// A recovery decision belongs to the person. An unmatched old row could be a
/// never-uploaded change or an old copy deleted elsewhere; neither is inferred.
struct LegacyReconciliationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [CollectionLegacyCandidate] = []
    @State private var errorMessage: String?
    @State private var uploading: UUID?
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var candidateToUpload: CollectionLegacyCandidate?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("These local records were kept safely because their earlier iCloud state is unclear. Upload only records you want to restore to iCloud. A record may have been deleted on another device.")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(candidate.title.isEmpty ? candidate.recordType : candidate.title)
                        Text(candidate.recordType).font(.caption).foregroundStyle(.secondary)
                        Button("Upload this recovered record") { candidateToUpload = candidate }
                            .disabled(!candidate.canUpload || uploading != nil)
                        if !candidate.canUpload { Text("Current sharing permissions do not allow uploading this record.").font(.caption) }
                    }
                }
                if hasMore { Button("Load more") { Task { await loadMore() } }.disabled(isLoading) }
                if isLoading { ProgressView() }
            }
            .navigationTitle("Review recovered changes")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { if candidates.isEmpty { await loadMore() } }
            .confirmationDialog("Restore this record to iCloud?", isPresented: Binding(get: { candidateToUpload != nil }, set: { if !$0 { candidateToUpload = nil } }), titleVisibility: .visible) {
                Button("Upload recovered record") {
                    guard let candidate = candidateToUpload else { return }
                    candidateToUpload = nil
                    Task {
                        uploading = candidate.id
                        defer { uploading = nil }
                        do {
                            try await store.authorizeLegacyUpload(candidate.id)
                            candidates.removeAll { $0.id == candidate.id }
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) { candidateToUpload = nil }
            } message: { Text("This explicitly restores the current local value, including any photo. Other collaborators may receive it.") }
        }
        .frame(minWidth: 300, minHeight: 360)
    }

    private func loadMore() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await store.legacyCandidates(limit: 50, offset: candidates.count)
            candidates.append(contentsOf: next)
            hasMore = next.count == 50
        } catch { errorMessage = error.localizedDescription }
    }
}
