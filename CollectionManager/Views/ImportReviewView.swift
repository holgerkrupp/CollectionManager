import SwiftUI
import UniformTypeIdentifiers

struct ImportColumnMappingPicker: View {
    let header: String
    let sample: String
    let existingMetadataFields: [MetadataFieldDefinition]
    var standardFields: [HTMLImportField] = HTMLImportField.allCases.filter { $0 != .ignore }
    var allowsNewMetadata = true
    var sourceLabel: String? = nil
    @Binding var destination: ImportColumnDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(header, selection: $destination) {
                Text("Ignore").tag(ImportColumnDestination.ignore)
                if !standardFields.isEmpty {
                    Divider()
                    ForEach(standardFields) { field in
                        Text(field.label).tag(ImportColumnDestination.standard(field))
                    }
                }
                if !existingMetadataFields.isEmpty {
                    Divider()
                    ForEach(existingMetadataFields) { field in
                        Text("Existing metadata: \(field.name)").tag(ImportColumnDestination.existingMetadata(field.id))
                    }
                }
                if allowsNewMetadata {
                    Divider()
                    ForEach(MetadataFieldType.allCases) { type in
                        Text("New metadata: \(type.label)").tag(ImportColumnDestination.newMetadata(type))
                    }
                }
            }
            .pickerStyle(.menu)
            if !sample.isEmpty {
                Text([sourceLabel, sample].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

struct ConditionalMappingRulesSection: View {
    let headers: [String]
    let statuses: [CollectionStatus]
    let metadataFields: [MetadataFieldDefinition]
    @Binding var rules: [ConditionalMappingRule]

    var body: some View {
        Section {
            ForEach($rules) { $rule in
                ConditionalMappingRuleEditor(headers: headers, statuses: statuses, metadataFields: metadataFields, rule: $rule)
            }
            .onDelete { rules.remove(atOffsets: $0) }

            Button { addRule() } label: { Label("Add conditional rule", systemImage: "plus.circle") }
                .disabled(headers.isEmpty || statuses.isEmpty)
        } header: {
            Text("Conditional rules")
        } footer: {
            Text("Values are compared after trimming and without case sensitivity. When multiple rules match, later rules can replace values set by earlier rules.")
        }
    }

    private func addRule() {
        guard let header = headers.first, let status = statuses.first else { return }
        rules.append(ConditionalMappingRule(sourceColumn: header, equalsValue: "", action: .status(status.id)))
    }
}

private enum ConditionalActionKind: String, CaseIterable, Identifiable {
    case status
    case metadata
    var id: String { rawValue }
    var label: String { self == .status ? "Set status" : "Set metadata" }
}

private struct ConditionalMappingRuleEditor: View {
    let headers: [String]
    let statuses: [CollectionStatus]
    let metadataFields: [MetadataFieldDefinition]
    @Binding var rule: ConditionalMappingRule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("If field", selection: $rule.sourceColumn) {
                if !headers.contains(where: { $0.localizedCaseInsensitiveCompare(rule.sourceColumn) == .orderedSame }) {
                    Text("Missing: \(rule.sourceColumn)").tag(rule.sourceColumn)
                }
                ForEach(headers, id: \.self) { Text($0).tag($0) }
            }
                .pickerStyle(.menu)
            TextField("Equals value", text: $rule.equalsValue)
            Picker("Then", selection: actionKind) {
                Text(ConditionalActionKind.status.label).tag(ConditionalActionKind.status)
                if !metadataFields.isEmpty { Text(ConditionalActionKind.metadata.label).tag(ConditionalActionKind.metadata) }
            }
            .pickerStyle(.segmented)

            switch rule.action {
            case .status:
                Picker("Status", selection: statusID) {
                    if case .status(let currentID) = rule.action, !statuses.contains(where: { $0.id == currentID }) {
                        Text("Unavailable status").tag(currentID)
                    }
                    ForEach(statuses) { Text($0.name).tag($0.id) }
                }
                    .pickerStyle(.menu)
            case .metadata:
                Picker("Metadata field", selection: metadataFieldID) {
                    if case .metadata(let currentID, _) = rule.action, !metadataFields.contains(where: { $0.id == currentID }) {
                        Text("Unavailable metadata field").tag(currentID)
                    }
                    ForEach(metadataFields) { Text($0.name).tag($0.id) }
                }
                    .pickerStyle(.menu)
                TextField("Value to set", text: metadataValue)
                if let field = selectedMetadataField {
                    Text("The value is parsed as \(field.type.label.lowercased()).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var actionKind: Binding<ConditionalActionKind> {
        Binding(get: {
            if case .metadata = rule.action { return .metadata }
            return .status
        }, set: { kind in
            switch kind {
            case .status:
                if let status = statuses.first { rule.action = .status(status.id) }
            case .metadata:
                if let field = metadataFields.first { rule.action = .metadata(fieldID: field.id, value: "") }
            }
        })
    }

    private var statusID: Binding<String> {
        Binding(get: {
            if case .status(let id) = rule.action { return id }
            return statuses.first?.id ?? ItemState.wanted.rawValue
        }, set: { rule.action = .status($0) })
    }

    private var metadataFieldID: Binding<UUID> {
        Binding(get: {
            if case .metadata(let fieldID, _) = rule.action { return fieldID }
            return metadataFields.first?.id ?? UUID()
        }, set: { newID in
            let value: String
            if case .metadata(_, let existingValue) = rule.action { value = existingValue } else { value = "" }
            rule.action = .metadata(fieldID: newID, value: value)
        })
    }

    private var metadataValue: Binding<String> {
        Binding(get: {
            if case .metadata(_, let value) = rule.action { return value }
            return ""
        }, set: { newValue in
            guard case .metadata(let fieldID, _) = rule.action else { return }
            rule.action = .metadata(fieldID: fieldID, value: newValue)
        })
    }

    private var selectedMetadataField: MetadataFieldDefinition? {
        guard case .metadata(let fieldID, _) = rule.action else { return nil }
        return metadataFields.first { $0.id == fieldID }
    }
}

struct ProductMetadataMappingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let snapshot: ProductSourceSnapshot
    @Binding var metadata: [String: MetadataValue]
    @State private var mapping: [ImportColumnDestination]
    @State private var didSuggestMapping = false

    private var fields: [ProductSourceField] { snapshot.sourceFields }

    init(snapshot: ProductSourceSnapshot, metadata: Binding<[String: MetadataValue]>) {
        self.snapshot = snapshot
        _metadata = metadata
        _mapping = State(initialValue: Array(repeating: .ignore, count: snapshot.sourceFields.count))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Provider", value: snapshot.provider)
                    LabeledContent("Barcode", value: snapshot.barcode)
                    LabeledContent("Fetched", value: snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                } footer: {
                    Text("Mapped values include app enrichments; Raw API values preserve the provider response. Only fields selected below are applied.")
                }

                Section("Map product fields") {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                        ImportColumnMappingPicker(
                            header: field.name,
                            sample: field.value,
                            existingMetadataFields: store.selectedCollection?.metadataFields ?? [],
                            standardFields: [],
                            sourceLabel: field.source,
                            destination: Binding(
                                get: { mapping.indices.contains(index) ? mapping[index] : .ignore },
                                set: { setMapping($0, at: index) }
                            )
                        )
                    }
                }
            }
            .navigationTitle("Map product metadata")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { applyMapping() }.disabled(!hasMappedFields) }
            }
            .onAppear {
                guard !didSuggestMapping else { return }
                mapping = CollectionImporter().suggestMetadataMapping(headers: fields.map(\.name), existingMetadataFields: store.selectedCollection?.metadataFields ?? [])
                didSuggestMapping = true
            }
        }
    }

    private var hasMappedFields: Bool {
        mapping.contains { destination in
            if case .existingMetadata = destination { return true }
            if case .newMetadata = destination { return true }
            return false
        }
    }

    private func setMapping(_ destination: ImportColumnDestination, at index: Int) {
        guard mapping.indices.contains(index) else { return }
        if case .existingMetadata(let fieldID) = destination {
            for otherIndex in mapping.indices where otherIndex != index && mapping[otherIndex] == .existingMetadata(fieldID) { mapping[otherIndex] = .ignore }
        }
        mapping[index] = destination
    }

    private func applyMapping() {
        let preparation = CollectionImporter().prepareMetadataMapping(headers: fields.map(\.name), values: fields.map(\.value), mapping: mapping, existingMetadataFields: store.selectedCollection?.metadataFields ?? [])
        store.addMetadataFields(preparation.newMetadataFields)
        metadata.merge(preparation.metadata) { _, mapped in mapped }
        dismiss()
    }
}

struct CSVMappingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let table: CSVImportTable
    @State private var mapping: [ImportColumnDestination]
    @State private var preparation: ImportPreparation?
    @State private var conditionalRules: [ConditionalMappingRule] = []
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

                ConditionalMappingRulesSection(headers: table.headers, statuses: store.statuses, metadataFields: store.selectedCollection?.metadataFields ?? [], rules: $conditionalRules)

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
            existingMetadataFields: store.selectedCollection?.metadataFields ?? [],
            conditionalRules: conditionalRules,
            validStatusIDs: Set(store.statuses.map(\.id))
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
