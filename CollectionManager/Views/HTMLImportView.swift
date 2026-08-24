import SwiftUI
import UniformTypeIdentifiers

struct HTMLImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL = ""
    @State private var tables: [HTMLImportTable] = []
    @State private var selectedTableIndex = 0
    @State private var showingFileImporter = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    TextField("https://… or local HTML file", text: $sourceURL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                    Button { loadRemotePage() } label: { Label("Read web page", systemImage: "globe") }.disabled(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    Button { showingFileImporter = true } label: { Label("Choose HTML file", systemImage: "doc.text") }
                }
                if isLoading { Section { ProgressView("Reading HTML…") } }
                if !tables.isEmpty {
                    Section("Detected objects") {
                        Picker("Object table", selection: $selectedTableIndex) { ForEach(Array(tables.enumerated()), id: \.offset) { index, table in Text("\(table.name) · \(table.rows.count) objects").tag(index) } }
                        NavigationLink { HTMLMappingView(table: tables[selectedTableIndex], sourceURL: sourceURL) } label: { Label("Adjust column mapping", systemImage: "rectangle.3.group") }
                    }
                    Section { Text("The importer detects real HTML tables first. For list-style pages, it falls back to repeated linked objects such as the drink entries on the example page.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Import web data")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.html, .text], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                do { tables = try HTMLImporter().parse(data: Data(contentsOf: url), name: url.lastPathComponent); sourceURL = url.absoluteString; selectedTableIndex = 0 } catch { errorMessage = error.localizedDescription }
            }
            .alert("Import failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }
    }

    private func loadRemotePage() {
        guard let url = URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" || url.scheme == "http" else { errorMessage = "Enter a valid web URL."; return }
        isLoading = true
        Task { do { let loaded = try await HTMLImporter().load(url: url); await MainActor.run { tables = loaded; selectedTableIndex = 0; isLoading = false } } catch { await MainActor.run { errorMessage = error.localizedDescription; isLoading = false } } }
    }
}

struct HTMLMappingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let table: HTMLImportTable
    let sourceURL: String
    @State private var mapping: [ImportColumnDestination]
    @State private var conditionalRules: [ConditionalMappingRule] = []
    @State private var preparation: ImportPreparation?
    @State private var didSuggestMapping = false
    @State private var fixedState: ItemState?
    @State private var saveForBackgroundSync = false
    @State private var intervalMinutes = 360
    @State private var addNewItems = true
    @State private var updateExistingStates = true
    @State private var tagSeparators = ",|;/"
    @State private var splitTagsOnWhitespace = false
    @State private var generateTagsFromTitle = false
    @State private var titleTagMode: TitleTagMode = .firstSegment
    @State private var titleSeparators = "-–—_:|/,"

    init(table: HTMLImportTable, sourceURL: String = "") { self.table = table; self.sourceURL = sourceURL; _mapping = State(initialValue: Array(repeating: .ignore, count: table.headers.count)) }

    var body: some View {
        Form {
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
            Section("Preview") {
                if previewDrafts.isEmpty {
                    Text("No preview objects. Map at least one column to Title.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(previewDrafts) { draft in
                        ImportDraftDetails(draft: draft)
                    }
                }
            }
            ConditionalMappingRulesSection(headers: table.headers, statuses: store.statuses, metadataFields: store.selectedCollection?.metadataFields ?? [], rules: $conditionalRules)
            Section("Import status") {
                Picker("Status for imported items", selection: $fixedState) {
                    Text("Use status from source").tag(ItemState?.none)
                    ForEach(store.statuses) { status in Text(status.name).tag(ItemState?.some(ItemState(rawValue: status.id))) }
                }
                Text(fixedState == nil ? "Each item keeps its mapped source status." : "This status will be applied to every imported item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Tags") {
                TextField("Tag separators", text: $tagSeparators)
                Toggle("Also split on spaces", isOn: $splitTagsOnWhitespace)
                Toggle("Generate tags from title", isOn: $generateTagsFromTitle)
                if generateTagsFromTitle {
                    Picker("Title tag mode", selection: $titleTagMode) {
                        ForEach(TitleTagMode.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Title separators", text: $titleSeparators)
                }
                Text("Separators can include comma, pipe, slash, hyphen, or any other special character.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Background web sync") {
                Toggle("Save these settings for background sync", isOn: $saveForBackgroundSync)
                    .disabled(!canSaveBackgroundSync)
                if saveForBackgroundSync {
                    Picker("Check for updates", selection: $intervalMinutes) {
                        ForEach([15, 60, 360, 720, 1440], id: \.self) { minutes in
                            Text(intervalLabel(minutes)).tag(minutes)
                        }
                    }
                    Toggle("Add new items", isOn: $addNewItems)
                    Toggle("Update existing statuses", isOn: $updateExistingStates)
                }
                if !canSaveBackgroundSync {
                    Text("Background sync is available only when this importer was opened with a web URL and a collection is selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section { Text("Suggestions are based on column names. You can change every mapping before reviewing the imported objects.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Map columns")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Review") { preparation = makePreparation() }.disabled(!mapping.contains(.standard(.title))) } }
        .onAppear {
            guard !didSuggestMapping else { return }
            mapping = HTMLImporter().suggestMapping(for: table, existingMetadataFields: store.selectedCollection?.metadataFields ?? [])
            didSuggestMapping = true
        }
        .sheet(item: $preparation) { preparation in
            ImportReviewView(
                drafts: preparation.drafts,
                useSourceDeduplication: true,
                metadataFieldsToCreate: preparation.newMetadataFields,
                metadataFields: preparation.metadataFields
            ) {
                saveBackgroundSyncIfNeeded(preparation: preparation)
            }
        }
    }

    private var previewDrafts: [ImportDraft] {
        Array(makePreparation().drafts.prefix(5))
    }

    private func makePreparation() -> ImportPreparation {
        let fields = store.selectedCollection?.metadataFields ?? []
        let prepared = HTMLImporter().prepareImport(from: table, mapping: mapping, existingMetadataFields: fields, conditionalRules: conditionalRules, validStatusIDs: Set(store.statuses.map(\.id)))
        var drafts = prepared.drafts
        if let fixedState {
            for index in drafts.indices { drafts[index].state = fixedState }
        }
        for index in drafts.indices {
            drafts[index].tags = TagUtilities.tags(title: drafts[index].title, existing: drafts[index].tags, rawTags: drafts[index].tags.joined(separator: ","), options: tagOptions)
        }
        return ImportPreparation(drafts: drafts, newMetadataFields: prepared.newMetadataFields, metadataFields: prepared.metadataFields)
    }

    private var tagOptions: TagGenerationOptions {
        var options = TagGenerationOptions()
        options.separators = tagSeparators
        options.splitOnWhitespace = splitTagsOnWhitespace
        options.generateFromTitle = generateTagsFromTitle
        options.titleMode = titleTagMode
        options.titleSeparators = titleSeparators
        return options
    }

    private var canSaveBackgroundSync: Bool {
        guard let url = URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return (url.scheme == "http" || url.scheme == "https") && store.selectedCollection != nil && mapping.contains(.standard(.title))
    }

    private func saveBackgroundSyncIfNeeded(preparation: ImportPreparation) {
        guard saveForBackgroundSync, canSaveBackgroundSync, let collectionID = store.selectedCollection?.id else { return }
        store.saveWebSync(WebSyncRecord(collectionID: collectionID, urlString: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines), tableName: table.name, headers: table.headers, mapping: resolvedMapping(using: preparation.newMetadataFields), conditionalRules: conditionalRules, intervalMinutes: intervalMinutes, addNewItems: addNewItems, updateExistingStates: updateExistingStates, fixedState: fixedState, tagOptions: tagOptions))
    }

    private func resolvedMapping(using newFields: [MetadataFieldDefinition]) -> [ImportColumnDestination] {
        var fieldIndex = 0
        return mapping.map { destination in
            guard case .newMetadata = destination, fieldIndex < newFields.count else { return destination }
            defer { fieldIndex += 1 }
            return .existingMetadata(newFields[fieldIndex].id)
        }
    }

    private func setMapping(_ destination: ImportColumnDestination, at index: Int) {
        guard mapping.indices.contains(index) else { return }
        switch destination {
        case .standard(let field):
            for otherIndex in mapping.indices where otherIndex != index && mapping[otherIndex] == .standard(field) { mapping[otherIndex] = .ignore }
        case .existingMetadata(let fieldID):
            for otherIndex in mapping.indices where otherIndex != index && mapping[otherIndex] == .existingMetadata(fieldID) { mapping[otherIndex] = .ignore }
        default: break
        }
        mapping[index] = destination
    }

    private func sampleValues(for column: Int) -> String {
        let values = table.rows.compactMap { column < $0.count ? $0[column].trimmingCharacters(in: .whitespacesAndNewlines) : nil }.filter { !$0.isEmpty }
        return values.isEmpty ? "No populated values" : values.prefix(3).joined(separator: " · ")
    }

    private func intervalLabel(_ minutes: Int) -> String {
        if minutes >= 1440 { return "Daily" }
        if minutes >= 60 { return "Every \(minutes / 60) hour\(minutes == 60 ? "" : "s")" }
        return "Every \(minutes) minutes"
    }
}
