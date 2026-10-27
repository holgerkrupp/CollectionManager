import SwiftUI
import UniformTypeIdentifiers

struct HTMLImportView: View {
    let collectionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL = ""
    @State private var loadedSource: LoadedHTMLSource?
    @State private var sourceWorker: Task<LoadedHTMLSource, Error>?
    @State private var sourceGeneration: UInt64 = 0
    @State private var selectedTableIndex = 0
    @State private var showingFileImporter = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// Source identity travels with the table batch, never with editable text.
    nonisolated private struct LoadedHTMLSource: Sendable {
        let url: URL
        let tables: [HTMLImportTable]
    }

    init(collectionID: UUID) { self.collectionID = collectionID }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    TextField("https://… or local HTML file", text: Binding(
                        get: { sourceURL },
                        set: { value in
                            guard value != sourceURL else { return }
                            invalidateSource()
                            sourceURL = value
                        }
                    ))
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                    Button { loadRemotePage() } label: { Label("Read web page", systemImage: "globe") }
                        .disabled(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    Button {
                        invalidateSource()
                        showingFileImporter = true
                    } label: { Label("Choose HTML file", systemImage: "doc.text") }
                }
                if isLoading { Section { ProgressView("Reading HTML…") } }
                if let loadedSource, !loadedSource.tables.isEmpty {
                    Section("Detected objects") {
                        Picker("Object table", selection: $selectedTableIndex) {
                            ForEach(Array(loadedSource.tables.enumerated()), id: \.offset) { index, table in
                                Text("\(table.name) · \(table.rows.count) objects").tag(index)
                            }
                        }
                        if loadedSource.tables.indices.contains(selectedTableIndex) {
                            let table = loadedSource.tables[selectedTableIndex]
                            NavigationLink {
                                HTMLMappingView(table: table, sourceURL: loadedSource.url.absoluteString, collectionID: collectionID)
                                    .id(table.id)
                            } label: { Label("Adjust column mapping", systemImage: "rectangle.3.group") }
                        }
                    }
                    Section { Text("The importer detects real HTML tables first. For list-style pages, it falls back to repeated linked objects such as the drink entries on the example page.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Import web data")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.html, .text], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                loadLocalFile(url)
            }
            .onDisappear { cancelLoading() }
            .alert("Import failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }
    }

    private func cancelLoading() {
        sourceWorker?.cancel()
        sourceWorker = nil
        sourceGeneration &+= 1
        isLoading = false
    }

    private func invalidateSource() {
        cancelLoading()
        loadedSource = nil
        selectedTableIndex = 0
        errorMessage = nil
    }

    private func loadRemotePage() {
        guard let url = URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || url.scheme == "http" else {
            errorMessage = String(localized: "Enter a valid web URL.")
            return
        }
        invalidateSource()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let tables = try await HTMLImporter().load(url: url)
            try Task.checkCancellation()
            return LoadedHTMLSource(url: url, tables: tables)
        }
        observe(worker)
    }

    private func loadLocalFile(_ url: URL) {
        invalidateSource()
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = String(localized: "The selected file could not be accessed.")
            return
        }
        sourceURL = url.absoluteString
        let worker = Task.detached(priority: .userInitiated) {
            defer { url.stopAccessingSecurityScopedResource() }
            try Task.checkCancellation()
            let tables = try HTMLImporter().parse(data: Data(contentsOf: url), name: url.lastPathComponent)
            try Task.checkCancellation()
            return LoadedHTMLSource(url: url, tables: tables)
        }
        observe(worker)
    }

    private func observe(_ worker: Task<LoadedHTMLSource, Error>) {
        let generation = sourceGeneration
        sourceWorker = worker
        isLoading = true
        Task {
            do {
                let result = try await worker.value
                guard sourceGeneration == generation, !worker.isCancelled else { return }
                loadedSource = result
                selectedTableIndex = 0
                sourceWorker = nil
                isLoading = false
            } catch {
                guard sourceGeneration == generation, !worker.isCancelled else { return }
                sourceWorker = nil
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct HTMLMappingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let table: HTMLImportTable
    let sourceURL: String
    let collectionID: UUID
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
    @State private var pendingBackgroundSync: PendingBackgroundSync?
    @State private var backgroundSyncMessage: String?
    @State private var suggestionWorker: Task<[ImportColumnDestination], Error>?
    @State private var reviewWorker: Task<ImportPreparation, Error>?
    @State private var reviewGeneration: UInt64 = 0
    @State private var isSuggestingMapping = false
    @State private var isPreparingReview = false
    @State private var preparationError: String?

    nonisolated private struct SuggestionIdentity: Hashable, Sendable {
        let tableID: UUID
        let fields: [MetadataFieldDefinition]
    }

    init(table: HTMLImportTable, sourceURL: String = "", collectionID: UUID) {
        self.table = table
        self.sourceURL = sourceURL
        self.collectionID = collectionID
        _mapping = State(initialValue: Array(repeating: .ignore, count: table.headers.count))
    }

    private var targetCollection: CollectionModel? { store.collections.first { $0.id == collectionID } }
    private var targetStatuses: [CollectionStatus] {
        guard let statuses = targetCollection?.statuses, !statuses.isEmpty else { return CollectionStatus.defaults }
        return statuses
    }

    var body: some View {
        Form {
            Section("Map columns") {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
                    ImportColumnMappingPicker(
                        header: header,
                        sample: sampleValues(for: index),
                        existingMetadataFields: targetCollection?.metadataFields ?? [],
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
                        ImportDraftDetails(draft: draft, collection: targetCollection)
                    }
                }
            }
            ConditionalMappingRulesSection(headers: table.headers, statuses: targetStatuses, metadataFields: targetCollection?.metadataFields ?? [], rules: $conditionalRules)
            Section("Import status") {
                Picker("Status for imported items", selection: $fixedState) {
                    Text("Use status from source").tag(ItemState?.none)
                    ForEach(targetStatuses) { status in Text(status.name).tag(ItemState?.some(ItemState(rawValue: status.id))) }
                }
                Text(fixedState == nil ? String(localized: "Each item keeps its mapped source status.") : String(localized: "This status will be applied to every imported item."))
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
                if let backgroundSyncMessage {
                    Text(backgroundSyncMessage).font(.footnote).foregroundStyle(.secondary)
                }
                if pendingBackgroundSync != nil {
                    Button("Retry saving background sync") { savePendingBackgroundSync() }
                }
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
                    Text("Background sync requires a web URL and an available target collection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section { Text("Suggestions are based on column names. You can change every mapping before reviewing the imported objects.").font(.footnote).foregroundStyle(.secondary) }
        }
        .disabled(isPreparingReview || isSuggestingMapping)
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                if isSuggestingMapping { ProgressView("Analyzing import…") }
                else if isPreparingReview { ProgressView("Preparing import review…") }
                if let preparationError { Text(preparationError).font(.footnote).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
        .navigationTitle("Map columns")
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("Review") { prepareReview() }
                .disabled(!mapping.contains(.standard(.title)) || isPreparingReview || isSuggestingMapping)
        } }
        .task(id: SuggestionIdentity(tableID: table.id, fields: targetCollection?.metadataFields ?? [])) {
            await suggestInitialMapping()
        }
        .onDisappear { suggestionWorker?.cancel(); reviewWorker?.cancel() }
        .sheet(item: $preparation) { preparation in
            ImportReviewView(
                drafts: preparation.drafts,
                collectionID: collectionID,
                useSourceDeduplication: true,
                metadataFieldsToCreate: preparation.newMetadataFields,
                metadataFields: preparation.metadataFields
            ) {
                saveBackgroundSyncIfNeeded(preparation: preparation)
            }
        }
    }

    private var previewDrafts: [ImportDraft] {
        let preview = HTMLImportTable(name: table.name, headers: table.headers, rows: Array(table.rows.prefix(5)))
        return Self.makePreparation(table: preview, mapping: mapping, fields: targetCollection?.metadataFields ?? [],
            rules: conditionalRules, validStatusIDs: Set(targetStatuses.map(\.id)), fixedState: fixedState, options: tagOptions).drafts
    }

    nonisolated private static func makePreparation(table: HTMLImportTable, mapping: [ImportColumnDestination],
        fields: [MetadataFieldDefinition], rules: [ConditionalMappingRule], validStatusIDs: Set<String>,
        fixedState: ItemState?, options: TagGenerationOptions) -> ImportPreparation {
        let prepared = HTMLImporter().prepareImport(from: table, mapping: mapping, existingMetadataFields: fields,
            conditionalRules: rules, validStatusIDs: validStatusIDs)
        var drafts = prepared.drafts
        if let fixedState {
            for index in drafts.indices { drafts[index].state = fixedState; drafts[index].stateWasExplicit = true }
        }
        for index in drafts.indices {
            drafts[index].tags = TagUtilities.tags(title: drafts[index].title, existing: drafts[index].tags,
                rawTags: drafts[index].tags.joined(separator: ","), options: options)
        }
        return ImportPreparation(drafts: drafts, newMetadataFields: prepared.newMetadataFields, metadataFields: prepared.metadataFields)
    }

    private func suggestInitialMapping() async {
        guard !didSuggestMapping, !Task.isCancelled else { return }
        isSuggestingMapping = true
        let table = self.table, fields = targetCollection?.metadataFields ?? []
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = HTMLImporter().suggestMapping(for: table, existingMetadataFields: fields)
            try Task.checkCancellation()
            return result
        }
        suggestionWorker = worker
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, !worker.isCancelled else { return }
            mapping = result
            didSuggestMapping = true
            isSuggestingMapping = false
        } catch {
            if !Task.isCancelled, !worker.isCancelled {
                isSuggestingMapping = false
                preparationError = error.localizedDescription
            }
        }
    }

    private func prepareReview() {
        guard !isPreparingReview, !isSuggestingMapping, mapping.contains(.standard(.title)) else { return }
        reviewWorker?.cancel()
        reviewGeneration &+= 1
        let generation = reviewGeneration, table = self.table, mapping = self.mapping
        let fields = targetCollection?.metadataFields ?? [], rules = conditionalRules
        let validIDs = Set(targetStatuses.map(\.id)), state = fixedState, options = tagOptions
        isPreparingReview = true
        preparationError = nil
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = Self.makePreparation(table: table, mapping: mapping, fields: fields, rules: rules,
                validStatusIDs: validIDs, fixedState: state, options: options)
            try Task.checkCancellation()
            return result
        }
        reviewWorker = worker
        Task {
            do {
                let result = try await worker.value
                guard reviewGeneration == generation else { return }
                isPreparingReview = false
                guard !worker.isCancelled, table.id == self.table.id, mapping == self.mapping,
                      fields == (targetCollection?.metadataFields ?? []), rules == conditionalRules,
                      validIDs == Set(targetStatuses.map(\.id)), state == fixedState, options == tagOptions else { return }
                preparation = result
            } catch {
                guard reviewGeneration == generation else { return }
                isPreparingReview = false
                if !worker.isCancelled { preparationError = error.localizedDescription }
            }
        }
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
        return (url.scheme == "http" || url.scheme == "https") && targetCollection != nil && mapping.contains(.standard(.title))
    }

    private struct PendingBackgroundSync {
        let collectionID: UUID
        let urlString: String
        let tableName: String
        let headers: [String]
        let mapping: [ImportColumnDestination]
        let conditionalRules: [ConditionalMappingRule]
        let intervalMinutes: Int
        let addNewItems: Bool
        let updateExistingStates: Bool
        let fixedState: ItemState?
        let tagOptions: TagGenerationOptions

        func makeRecord() -> WebSyncRecord {
            WebSyncRecord(collectionID: collectionID, urlString: urlString, tableName: tableName,
                          headers: headers, mapping: mapping, conditionalRules: conditionalRules,
                          intervalMinutes: intervalMinutes, addNewItems: addNewItems,
                          updateExistingStates: updateExistingStates, fixedState: fixedState, tagOptions: tagOptions)
        }
    }

    private func saveBackgroundSyncIfNeeded(preparation: ImportPreparation) {
        guard saveForBackgroundSync, canSaveBackgroundSync else { return }
        pendingBackgroundSync = PendingBackgroundSync(collectionID: collectionID,
            urlString: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines), tableName: table.name,
            headers: table.headers, mapping: resolvedMapping(using: preparation.newMetadataFields),
            conditionalRules: conditionalRules, intervalMinutes: intervalMinutes, addNewItems: addNewItems,
            updateExistingStates: updateExistingStates, fixedState: fixedState, tagOptions: tagOptions)
        savePendingBackgroundSync()
    }

    private func savePendingBackgroundSync() {
        guard let pendingBackgroundSync else { return }
        // Each retry creates a new model: a failed transaction may invalidate
        // its inserted model, but this value-only configuration remains safe.
        guard store.saveWebSync(pendingBackgroundSync.makeRecord()) else {
            backgroundSyncMessage = String(localized: "Your items were imported, but background sync settings could not be saved. The imported items remain in your library. Retry saving these settings here.")
            return
        }
        self.pendingBackgroundSync = nil
        backgroundSyncMessage = String(localized: "Your items were imported and background sync settings are saved.")
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
        let values = table.rows.prefix(5).compactMap { column < $0.count ? $0[column].trimmingCharacters(in: .whitespacesAndNewlines) : nil }.filter { !$0.isEmpty }
        return values.isEmpty ? String(localized: "No populated values") : values.prefix(3).joined(separator: " · ")
    }

    private func intervalLabel(_ minutes: Int) -> String {
        if minutes >= 1440 { return String(localized: "Daily") }
        if minutes >= 60 { return String(localized: "Interval in hours: \(minutes / 60)") }
        return String(localized: "Interval in minutes: \(minutes)")
    }
}
