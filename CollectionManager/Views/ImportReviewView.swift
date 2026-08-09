import SwiftUI
import UniformTypeIdentifiers

struct ImportReviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let drafts: [ImportDraft]
    let useSourceDeduplication: Bool
    let onImport: (() -> Void)?
    @State private var selected: Set<UUID>
    @State private var showingDeduplicationConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var maintenanceMessage: String?

    init(drafts: [ImportDraft], useSourceDeduplication: Bool = false, onImport: (() -> Void)? = nil) {
        self.drafts = drafts
        self.useSourceDeduplication = useSourceDeduplication
        self.onImport = onImport
        _selected = State(initialValue: Set(drafts.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Ready to import") {
                    ForEach(drafts) { draft in
                        HStack {
                            Image(systemName: selected.contains(draft.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(draft.id) ? Color.accentColor : Color.secondary)
                                .onTapGesture { toggleSelection(draft.id) }
                            ImportDraftDetails(draft: draft)
                            Spacer()
                        }
                    }
                }

                if useSourceDeduplication {
                    Section("Imported item maintenance") {
                        Button("Deduplicate imported items") { showingDeduplicationConfirmation = true }
                        Button("Delete all imported items", role: .destructive) { showingDeleteConfirmation = true }
                        if let maintenanceMessage {
                            Text(maintenanceMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("Review imported rows before they become permanent items.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Review import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selected.count)") { importSelected() }
                        .disabled(selected.isEmpty)
                }
            }
            .confirmationDialog("Remove duplicate imported items? The newest copy will be kept.", isPresented: $showingDeduplicationConfirmation, titleVisibility: .visible) {
                Button("Deduplicate", role: .destructive) {
                    let removed = store.deduplicateImportedItems()
                    maintenanceMessage = removed == 0 ? "No duplicates found." : "Removed \(removed) duplicate item\(removed == 1 ? "" : "s")."
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete all imported items? This cannot be undone.", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    let removed = store.deleteAllImportedItems()
                    maintenanceMessage = "Deleted \(removed) imported item\(removed == 1 ? "" : "s")."
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func importSelected() {
        let selectedDrafts = drafts.filter { selected.contains($0.id) }
        if useSourceDeduplication {
            store.importDrafts(selectedDrafts)
        } else {
            for draft in selectedDrafts {
                store.addItem(title: draft.title, brand: draft.brand, variant: draft.variant, description: draft.description, state: draft.state, quantity: draft.quantity, tags: draft.tags, barcode: draft.barcode, sourceIdentifier: draft.sourceIdentifier)
            }
        }
        onImport?()
        dismiss()
    }
}

struct ImportDraftDetails: View {
    @Environment(AppStore.self) private var store
    let draft: ImportDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(draft.title)
                .font(.headline)

            ImportDraftField(label: "Brand", value: draft.brand)
            ImportDraftField(label: "Variant", value: draft.variant)
            ImportDraftField(label: "Description", value: draft.description)
            ImportDraftField(label: "Status", value: store.status(for: draft.state).name)
            ImportDraftField(label: "Quantity", value: "\(draft.quantity)")
            ImportDraftField(label: "Barcode", value: draft.barcode.map { "\($0.value) (\($0.type))" } ?? "—")
            ImportDraftField(label: "Tags", value: draft.tags.isEmpty ? "—" : draft.tags.joined(separator: ", "))
            ImportDraftField(label: "Source", value: draft.sourceIdentifier ?? "—")
        }
    }
}

private struct ImportDraftField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
    }
}
