import SwiftUI
import UniformTypeIdentifiers

struct ImportColumnMappingPicker: View {
    let header: String
    let sample: String
    let existingMetadataFields: [MetadataFieldDefinition]
    @Binding var destination: ImportColumnDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(header, selection: $destination) {
                Text("Ignore").tag(ImportColumnDestination.ignore)
                Divider()
                ForEach(HTMLImportField.allCases.filter { $0 != .ignore }) { field in
                    Text(field.label).tag(ImportColumnDestination.standard(field))
                }
                if !existingMetadataFields.isEmpty {
                    Divider()
                    ForEach(existingMetadataFields) { field in
                        Text("Existing metadata: \(field.name)").tag(ImportColumnDestination.existingMetadata(field.id))
                    }
                }
                Divider()
                ForEach(MetadataFieldType.allCases) { type in
                    Text("New metadata: \(type.label)").tag(ImportColumnDestination.newMetadata(type))
                }
            }
            .pickerStyle(.menu)
            if !sample.isEmpty {
                Text(sample)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

struct CSVMappingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let table: CSVImportTable
    @State private var mapping: [ImportColumnDestination]
    @State private var preparation: ImportPreparation?
    @State private var didSuggestMapping = false

    init(table: CSVImportTable) {
        self.table = table
        _mapping = State(initialValue: Array(repeating: .ignore, count: table.headers.count))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Rows", value: "\(table.rows.count)")
                } footer: {
                    Text("Choose where each source column should be imported. New metadata fields use the source column name.")
                }

                Section("Map columns") {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
                        ImportColumnMappingPicker(
                            header: header,
                            sample: sampleValues(for: index),
                            existingMetadataFields: store.selectedCollection?.metadataFields ?? [],
                            destination: Binding(
                                get: { mapping.indices.contains(index) ? mapping[index] : .ignore },
                                set: { setMapping($0, at: index) }
                            )
                        )
                    }
                }

                Section {
                    Text("Number and Date are suggested only when the populated source values can be parsed. You can override every suggestion before reviewing the import.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Map CSV columns")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { prepareReview() }
                        .disabled(!mapping.contains(.standard(.title)))
                }
            }
            .onAppear {
                guard !didSuggestMapping else { return }
                mapping = CollectionImporter().suggestMapping(for: table, existingMetadataFields: store.selectedCollection?.metadataFields ?? [])
                didSuggestMapping = true
            }
            .sheet(item: $preparation) { preparation in
                ImportReviewView(
                    drafts: preparation.drafts,
                    metadataFieldsToCreate: preparation.newMetadataFields,
                    metadataFields: preparation.metadataFields,
                    onImport: { dismiss() }
                )
            }
        }
    }

    private func setMapping(_ destination: ImportColumnDestination, at index: Int) {
        guard mapping.indices.contains(index) else { return }
        switch destination {
        case .standard(let field):
            for otherIndex in mapping.indices where otherIndex != index && mapping[otherIndex] == .standard(field) {
                mapping[otherIndex] = .ignore
            }
        case .existingMetadata(let fieldID):
            for otherIndex in mapping.indices where otherIndex != index && mapping[otherIndex] == .existingMetadata(fieldID) {
                mapping[otherIndex] = .ignore
            }
        default:
            break
        }
        mapping[index] = destination
    }

    private func sampleValues(for column: Int) -> String {
        let values = table.rows.compactMap { column < $0.count ? $0[column].trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            .filter { !$0.isEmpty }
        return values.isEmpty ? "No populated values" : values.prefix(3).joined(separator: " · ")
    }

    private func prepareReview() {
        preparation = CollectionImporter().prepareImport(
            from: table,
            mapping: mapping,
            existingMetadataFields: store.selectedCollection?.metadataFields ?? []
        )
    }
}

struct ImportReviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let drafts: [ImportDraft]
    let useSourceDeduplication: Bool
    let onImport: (() -> Void)?
    let metadataFieldsToCreate: [MetadataFieldDefinition]
    let metadataFields: [MetadataFieldDefinition]
    @State private var selected: Set<UUID>
    @State private var showingDeduplicationConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var maintenanceMessage: String?

    init(drafts: [ImportDraft], useSourceDeduplication: Bool = false, metadataFieldsToCreate: [MetadataFieldDefinition] = [], metadataFields: [MetadataFieldDefinition] = [], onImport: (() -> Void)? = nil) {
        self.drafts = drafts
        self.useSourceDeduplication = useSourceDeduplication
        self.metadataFieldsToCreate = metadataFieldsToCreate
        self.metadataFields = metadataFields
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
                            ImportDraftDetails(draft: draft, metadataFields: metadataFields)
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
        store.addMetadataFields(metadataFieldsToCreate)
        if useSourceDeduplication {
            store.importDrafts(selectedDrafts)
        } else {
            for draft in selectedDrafts {
                store.addItem(title: draft.title, brand: draft.brand, variant: draft.variant, description: draft.description, state: draft.state, quantity: draft.quantity, tags: draft.tags, metadata: draft.metadata, barcode: draft.barcode, sourceIdentifier: draft.sourceIdentifier)
            }
        }
        onImport?()
        dismiss()
    }
}

struct ImportDraftDetails: View {
    @Environment(AppStore.self) private var store
    let draft: ImportDraft
    var metadataFields: [MetadataFieldDefinition] = []

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
            ForEach(metadataFields) { field in
                if let value = draft.metadata[field.storageKey] {
                    ImportDraftField(label: field.name, value: value.displayValue)
                }
            }
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
