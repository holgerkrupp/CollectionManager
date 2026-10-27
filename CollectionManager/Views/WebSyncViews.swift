import SwiftUI

struct WebSyncListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditor = false
    @State private var editingSync: WebSyncRecord?
    @State private var editorCollectionID: UUID?

    var body: some View {
        NavigationStack {
            List {
                if store.webSyncs.isEmpty {
                    ContentUnavailableView("No web sources", systemImage: "globe", description: Text("Add a source to keep this collection current."))
                } else {
                    ForEach(store.webSyncs, id: \.id) { sync in
                        WebSyncRow(sync: sync) {
                            editingSync = sync
                            editorCollectionID = sync.collectionID
                            showingEditor = true
                        }
                    }
                    .onDelete { offsets in offsets.map { store.webSyncs[$0] }.forEach(store.deleteWebSync) }
                }
            }
            .navigationTitle("Web sync")
            .toolbar {
                ToolbarItem(placement: .platformLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .platformTrailing) {
                    Button {
                        guard let id = store.selectedCollection?.id else { return }
                        editingSync = nil
                        editorCollectionID = id
                        showingEditor = true
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingEditor) {
                if let editorCollectionID {
                    WebSyncEditorView(collectionID: editorCollectionID, sync: editingSync)
                }
            }
        }
    }
}

struct WebSyncRow: View {
    @Environment(AppStore.self) private var store
    let sync: WebSyncRecord
    let onEdit: () -> Void

    var body: some View {
        HStack {
            Image(systemName: sync.enabled ? "arrow.triangle.2.circlepath.circle.fill" : "pause.circle")
                .foregroundStyle(sync.enabled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading) {
                Text(sync.urlString).lineLimit(1)
                Text("\(intervalLabel) · Last sync: \(sync.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Never synced"))")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = sync.lastError { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1) }
            }
            Spacer()
            if let url = URL(string: sync.urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                Link(destination: url) { Image(systemName: "safari") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open in default browser")
            }
            Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.borderless)
            Button { Task { await store.syncWebSource(sync) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
        }
        .contextMenu {
            if let url = URL(string: sync.urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                Link(destination: url) { Label("Open in default browser", systemImage: "safari") }
            }
            Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
            Button { Task { await store.syncWebSource(sync) } } label: { Label("Sync now", systemImage: "arrow.clockwise") }
            Button(role: .destructive) { store.deleteWebSync(sync) } label: { Label("Remove source", systemImage: "trash") }
        }
    }

    private var intervalLabel: String {
        if sync.intervalMinutes >= 1440 { return String(localized: "Daily") }
        if sync.intervalMinutes >= 60 { return String(localized: "Interval in hours: \(sync.intervalMinutes / 60)") }
        return String(localized: "Interval in minutes: \(sync.intervalMinutes)")
    }
}

struct WebSyncEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let collectionID: UUID
    let existingSync: WebSyncRecord?
    @State private var urlString: String
    @State private var loadedSource: LoadedSource?
    @State private var loadWorker: Task<LoadedSource, Error>?
    @State private var saveWorker: Task<ImportPreparation, Error>?
    @State private var sourceGeneration: UInt64 = 0
    @State private var isSaving = false

    nonisolated private struct LoadedSource: Sendable {
        let url: URL
        let tables: [HTMLImportTable]
        let suggestions: [[ImportColumnDestination]]
    }

    private var tables: [HTMLImportTable] { loadedSource?.tables ?? [] }
    private var targetCollection: CollectionModel? { store.collections.first { $0.id == collectionID } }
    private var metadataFields: [MetadataFieldDefinition] { targetCollection?.metadataFields ?? [] }
    private var targetStatuses: [CollectionStatus] {
        guard let statuses = targetCollection?.statuses, !statuses.isEmpty else { return CollectionStatus.defaults }
        return statuses
    }
    private var canSave: Bool {
        guard !isLoading, !isSaving, let loadedSource, tables.indices.contains(selectedTable),
              let editedURL = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return editedURL == loadedSource.url && mapping.count == tables[selectedTable].headers.count && mapping.contains(.standard(.title))
    }
    @State private var selectedTable = 0
    @State private var mapping: [ImportColumnDestination]
    @State private var conditionalRules: [ConditionalMappingRule]
    @State private var intervalMinutes: Int
    @State private var addNewItems: Bool
    @State private var updateExistingStates: Bool
    @State private var fixedState: ItemState?
    @State private var tagSeparators: String
    @State private var splitTagsOnWhitespace: Bool
    @State private var generateTagsFromTitle: Bool
    @State private var titleTagMode: TitleTagMode
    @State private var titleSeparators: String
    @State private var isLoading = false
    @State private var errorMessage: String?
    private let intervals = [15, 60, 360, 720, 1440]

    init(collectionID: UUID, sync: WebSyncRecord? = nil) {
        self.collectionID = collectionID
        existingSync = sync
        _urlString = State(initialValue: sync?.urlString ?? "")
        _mapping = State(initialValue: sync?.mapping ?? [])
        _conditionalRules = State(initialValue: sync?.conditionalRules ?? [])
        _intervalMinutes = State(initialValue: sync?.intervalMinutes ?? 360)
        _addNewItems = State(initialValue: sync?.addNewItems ?? true)
        _updateExistingStates = State(initialValue: sync?.updateExistingStates ?? true)
        _fixedState = State(initialValue: sync?.fixedState)
        _tagSeparators = State(initialValue: sync?.tagOptions.separators ?? ",|;/")
        _splitTagsOnWhitespace = State(initialValue: sync?.tagOptions.splitOnWhitespace ?? false)
        _generateTagsFromTitle = State(initialValue: sync?.tagOptions.generateFromTitle ?? false)
        _titleTagMode = State(initialValue: sync?.tagOptions.titleMode ?? .firstSegment)
        _titleSeparators = State(initialValue: sync?.tagOptions.titleSeparators ?? "-–—_:|/,")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    TextField("https://…", text: Binding(get: { urlString }, set: { value in
                        guard value != urlString else { return }
                        invalidateSource()
                        urlString = value
                    }))
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                    Button { load() } label: { Label(isLoading ? String(localized: "Reading…") : String(localized: "Read and detect objects"), systemImage: "globe") }.disabled(isLoading)
                }
                if tables.indices.contains(selectedTable) {
                    Section("Detected table") {
                        Picker("Object table", selection: Binding(get: { selectedTable }, set: { index in
                            guard let loadedSource, loadedSource.tables.indices.contains(index) else { return }
                            selectedTable = index
                            mapping = loadedSource.suggestions[index]
                        })) {
                            ForEach(Array(tables.enumerated()), id: \.offset) { index, table in Text("\(table.name) · Objects: \(table.rows.count)").tag(index) }
                        }
                        ForEach(Array(tables[selectedTable].headers.enumerated()), id: \.offset) { index, header in
                            ImportColumnMappingPicker(
                                header: header,
                                sample: sampleValues(for: index),
                                existingMetadataFields: metadataFields,
                                destination: Binding(
                                    get: { mapping.indices.contains(index) ? mapping[index] : .ignore },
                                    set: { setMapping($0, at: index) }
                                )
                            )
                        }
                    }
                    ConditionalMappingRulesSection(headers: tables[selectedTable].headers, statuses: targetStatuses, metadataFields: metadataFields, rules: $conditionalRules)
                }
                Section("Reconciliation") {
                    Picker("Check for updates", selection: $intervalMinutes) { ForEach(intervals, id: \.self) { Text(intervalLabel($0)).tag($0) } }
                    Toggle("Add new objects", isOn: $addNewItems)
                    Toggle("Update existing statuses", isOn: $updateExistingStates)
                    Picker("State to apply", selection: $fixedState) {
                        Text("Use status from source").tag(ItemState?.none)
                        ForEach(targetStatuses) { status in Text(status.name).tag(ItemState?.some(ItemState(rawValue: status.id))) }
                    }
                }
                Section("Tags") {
                    TextField("Tag separators", text: $tagSeparators)
                    Toggle("Also split on spaces", isOn: $splitTagsOnWhitespace)
                    Toggle("Generate tags from title", isOn: $generateTagsFromTitle)
                    if generateTagsFromTitle {
                        Picker("Title tag mode", selection: $titleTagMode) { ForEach(TitleTagMode.allCases) { Text($0.label).tag($0) } }
                        TextField("Title separators", text: $titleSeparators)
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .onDisappear { cancelLoading(); saveWorker?.cancel() }
            .navigationTitle(existingSync == nil ? String(localized: "New web sync") : String(localized: "Edit web sync"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
            .task { if tables.isEmpty, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { load() } }
            .alert("Could not read source", isPresented: Binding(get: { errorMessage != nil && tables.isEmpty }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        guard canSave, let loadedSource, let collection = targetCollection,
              store.selectedCollection?.id == collectionID else {
            errorMessage = String(localized: "Select the collection before saving this web sync.")
            return
        }
        let table = tables[selectedTable], sourceURL = loadedSource.url.absoluteString
        let fields = collection.metadataFields, sourceMapping = mapping, rules = conditionalRules
        let generation = sourceGeneration, interval = intervalMinutes
        let addsItems = addNewItems, updatesStates = updateExistingStates, state = fixedState, options = tagOptions
        isSaving = true
        errorMessage = nil
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = HTMLImporter().prepareImport(from: table, mapping: sourceMapping, existingMetadataFields: fields)
            try Task.checkCancellation()
            return result
        }
        saveWorker = worker
        Task {
            defer { isSaving = false }
            do {
                let preparation = try await worker.value
                guard !worker.isCancelled, sourceGeneration == generation,
                      self.loadedSource?.url.absoluteString == sourceURL,
                      tables.indices.contains(selectedTable), tables[selectedTable].id == table.id,
                      mapping == sourceMapping, metadataFields == fields,
                      store.selectedCollection?.id == collectionID else {
                    if !worker.isCancelled { errorMessage = String(localized: "The source or collection changed. Read the source again before saving.") }
                    return
                }
                let persistedMapping = resolvedMapping(using: preparation.newMetadataFields)
                let committed: Bool
                if let existingSync {
                    committed = store.updateWebSync(existingSync, metadataFieldsToCreate: preparation.newMetadataFields) { record in
                        // The repository resolves/checks the stored record before
                        // this closure runs, and commits fields/config together.
                        record.urlString = sourceURL
                        record.tableName = table.name
                        record.headersJSON = String(decoding: try JSONEncoder().encode(table.headers), as: UTF8.self)
                        record.mappingJSON = String(decoding: try JSONEncoder().encode(persistedMapping), as: UTF8.self)
                        record.conditionalRulesJSON = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
                        record.intervalMinutes = interval
                        record.addNewItems = addsItems
                        record.updateExistingStates = updatesStates
                        record.fixedStateRawValue = state?.rawValue
                        record.tagSeparators = options.separators
                        record.splitTagsOnWhitespace = options.splitOnWhitespace
                        record.generateTagsFromTitle = options.generateFromTitle
                        record.titleTagModeRawValue = options.titleMode.rawValue
                        record.titleSeparators = options.titleSeparators
                    }
                } else {
                    let record = WebSyncRecord(collectionID: collectionID, urlString: sourceURL, tableName: table.name,
                        headers: table.headers, mapping: persistedMapping, conditionalRules: rules,
                        intervalMinutes: interval, addNewItems: addsItems, updateExistingStates: updatesStates,
                        fixedState: state, tagOptions: options)
                    committed = store.saveWebSync(record, metadataFieldsToCreate: preparation.newMetadataFields)
                }
                guard committed else {
                    errorMessage = store.persistenceError ?? store.itemActionError ?? String(localized: "The web sync settings could not be saved.")
                    store.persistenceError = nil
                    store.itemActionError = nil
                    return
                }
                dismiss()
            } catch {
                if !worker.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    private func intervalLabel(_ minutes: Int) -> String {
        if minutes >= 1440 { return String(localized: "Daily") }
        if minutes >= 60 { return String(localized: "Interval in hours: \(minutes / 60)") }
        return String(localized: "Interval in minutes: \(minutes)")
    }

    private func cancelLoading() {
        loadWorker?.cancel()
        loadWorker = nil
        sourceGeneration &+= 1
        isLoading = false
    }

    private func invalidateSource() {
        cancelLoading()
        loadedSource = nil
        selectedTable = 0
        mapping = []
        errorMessage = nil
    }

    private func load() {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            errorMessage = String(localized: "Enter a valid HTTP(S) URL.")
            return
        }
        invalidateSource()
        isLoading = true
        let generation = sourceGeneration, fields = metadataFields
        // Persistent models never cross to the detached parser/suggestion task.
        let savedURL = existingSync?.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedTableName = existingSync?.tableName
        let savedHeaders = existingSync?.headers
        let savedMapping = existingSync?.mapping
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let tables = try await HTMLImporter().load(url: url)
            var suggestions: [[ImportColumnDestination]] = []
            for table in tables {
                try Task.checkCancellation()
                suggestions.append(HTMLImporter().suggestMapping(for: table, existingMetadataFields: fields))
            }
            try Task.checkCancellation()
            return LoadedSource(url: url, tables: tables, suggestions: suggestions)
        }
        loadWorker = worker
        Task {
            do {
                let result = try await worker.value
                guard sourceGeneration == generation, !worker.isCancelled else { return }
                isLoading = false
                loadWorker = nil
                guard metadataFields == fields else {
                    errorMessage = String(localized: "The source or collection changed. Read the source again before saving.")
                    return
                }
                loadedSource = result
                guard !result.tables.isEmpty else { return }
                let sameSource = URL(string: savedURL ?? "") == result.url
                let index = sameSource ? result.tables.firstIndex { $0.name == savedTableName } ?? 0 : 0
                selectedTable = index
                let table = result.tables[index]
                if sameSource, table.name == savedTableName, savedHeaders == table.headers,
                   let savedMapping, savedMapping.count == table.headers.count {
                    mapping = savedMapping
                } else {
                    mapping = result.suggestions[index]
                }
            } catch {
                guard sourceGeneration == generation, !worker.isCancelled else { return }
                loadWorker = nil
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private var tagOptions: TagGenerationOptions {
        var options = TagGenerationOptions()
        options.separators = tagSeparators; options.splitOnWhitespace = splitTagsOnWhitespace; options.generateFromTitle = generateTagsFromTitle; options.titleMode = titleTagMode; options.titleSeparators = titleSeparators
        return options
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
        guard tables.indices.contains(selectedTable) else { return "" }
        let values = tables[selectedTable].rows.compactMap { column < $0.count ? $0[column].trimmingCharacters(in: .whitespacesAndNewlines) : nil }.filter { !$0.isEmpty }
        return values.isEmpty ? String(localized: "No populated values") : values.prefix(3).joined(separator: " · ")
    }

    private func resolvedMapping(using newFields: [MetadataFieldDefinition]) -> [ImportColumnDestination] {
        var fieldIndex = 0
        return mapping.map { destination in
            guard case .newMetadata = destination, fieldIndex < newFields.count else { return destination }
            defer { fieldIndex += 1 }
            return .existingMetadata(newFields[fieldIndex].id)
        }
    }
}
