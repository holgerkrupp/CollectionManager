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

struct ImportReviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let drafts: [ImportDraft]
    let useSourceDeduplication: Bool
    let onImport: (() -> Void)?
    let metadataFieldsToCreate: [MetadataFieldDefinition]
    let metadataFields: [MetadataFieldDefinition]
    let allowsDuplicates: Bool
    @State private var selected: Set<UUID>
    @State private var showingDeduplicationConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var maintenanceMessage: String?

    init(drafts: [ImportDraft], useSourceDeduplication: Bool = false, metadataFieldsToCreate: [MetadataFieldDefinition] = [], metadataFields: [MetadataFieldDefinition] = [], allowsDuplicates: Bool = false, onImport: (() -> Void)? = nil) {
        self.drafts = drafts
        self.useSourceDeduplication = useSourceDeduplication
        self.allowsDuplicates = allowsDuplicates
        self.metadataFieldsToCreate = metadataFieldsToCreate
        self.metadataFields = metadataFields
        self.onImport = onImport
        _selected = State(initialValue: Set(drafts.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button(selected.count == drafts.count ? "Deselect all" : "Select all") {
                            selected = selected.count == drafts.count ? [] : Set(drafts.map(\.id))
                        }
                        Spacer()
                        Text("\(selected.count) of \(drafts.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Ready to import") {
                    ForEach(drafts) { draft in
                        Button { toggleSelection(draft.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selected.contains(draft.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(draft.id) ? Color.accentColor : Color.secondary)
                                ImportDraftDetails(draft: draft, metadataFields: metadataFields)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
                    Text(allowsDuplicates ? "Every selected row becomes its own item, even when another item has the same title, brand and variant." : "Rows whose title, brand and variant already exist in the collection are skipped.")
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
        // A sheet on macOS sizes itself to its content, and a List has no
        // intrinsic height, so without this the review list collapses to nothing.
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 620)
        #endif
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
                store.addItem(title: draft.title, brand: draft.brand, variant: draft.variant, description: draft.description, state: draft.state, quantity: draft.quantity, tags: draft.tags, metadata: draft.metadata, barcode: draft.barcode, sourceIdentifier: draft.sourceIdentifier, allowsDuplicates: allowsDuplicates)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(draft.title)
                .font(.headline)
            // A row per field made a 100-row import unreadable, so only the
            // fields this row actually fills are listed, on one wrapped line.
            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        func add(_ label: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            parts.append("\(label): \(trimmed)")
        }
        add("Brand", draft.brand)
        add("Variant", draft.variant)
        add("Description", draft.description)
        add("Status", store.status(for: draft.state).name)
        if draft.quantity != 1 { add("Quantity", "\(draft.quantity)") }
        if let barcode = draft.barcode { add("Barcode", barcode.value) }
        if !draft.tags.isEmpty { add("Tags", draft.tags.joined(separator: ", ")) }
        for field in metadataFields {
            if let value = draft.metadata[field.storageKey] { add(field.name, value.displayValue) }
        }
        return parts.joined(separator: "  ·  ")
    }
}
