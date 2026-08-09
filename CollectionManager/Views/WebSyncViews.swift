import SwiftUI

struct WebSyncListView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditor = false
    @State private var editingSync: WebSyncRecord?

    var body: some View {
        NavigationStack {
            List {
                if store.webSyncs.isEmpty {
                    ContentUnavailableView("No web sources", systemImage: "globe", description: Text("Add a source to keep this collection current."))
                } else {
                    ForEach(store.webSyncs, id: \.id) { sync in
                        WebSyncRow(sync: sync) {
                            editingSync = sync
                            showingEditor = true
                        }
                    }
                    .onDelete { offsets in offsets.map { store.webSyncs[$0] }.forEach(store.deleteWebSync) }
                }
            }
            .navigationTitle("Web sync")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingSync = nil
                        showingEditor = true
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingEditor) {
                if let collection = store.selectedCollection {
                    WebSyncEditorView(collectionID: collection.id, sync: editingSync)
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
                Text("Every \(intervalLabel) · \(sync.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never synced")")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = sync.lastError { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1) }
            }
            Spacer()
            Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.borderless)
            Button { Task { await store.syncWebSource(sync) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
        }
        .contextMenu {
            Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
            Button { Task { await store.syncWebSource(sync) } } label: { Label("Sync now", systemImage: "arrow.clockwise") }
            Button(role: .destructive) { store.deleteWebSync(sync) } label: { Label("Remove source", systemImage: "trash") }
        }
    }

    private var intervalLabel: String {
        if sync.intervalMinutes >= 1440 { return "daily" }
        if sync.intervalMinutes >= 60 { return "every \(sync.intervalMinutes / 60)h" }
        return "every \(sync.intervalMinutes)m"
    }
}

struct WebSyncEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let collectionID: UUID
    let existingSync: WebSyncRecord?
    @State private var urlString: String
    @State private var tables: [HTMLImportTable] = []
    @State private var selectedTable = 0
    @State private var mapping: [HTMLImportField]
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
        _urlString = State(initialValue: sync?.urlString ?? "https://compendion.net/dirtyminutesleft/drinks/")
        _mapping = State(initialValue: sync?.mapping ?? [])
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
                    TextField("https://…", text: $urlString).textInputAutocapitalization(.never).keyboardType(.URL)
                    Button { load() } label: { Label(isLoading ? "Reading…" : "Read and detect objects", systemImage: "globe") }.disabled(isLoading)
                }
                if !tables.isEmpty {
                    Section("Detected table") {
                        Picker("Object table", selection: $selectedTable) {
                            ForEach(Array(tables.enumerated()), id: \.offset) { index, table in Text("\(table.name) · \(table.rows.count) objects").tag(index) }
                        }
                        .onChange(of: selectedTable) { _, index in mapping = HTMLImporter().suggestMapping(headers: tables[index].headers) }
                        ForEach(Array(tables[selectedTable].headers.enumerated()), id: \.offset) { index, header in
                            Picker(header, selection: Binding(get: { mapping.indices.contains(index) ? mapping[index] : .ignore }, set: { if mapping.indices.contains(index) { mapping[index] = $0 } })) {
                                ForEach(HTMLImportField.allCases) { Text($0.label).tag($0) }
                            }
                        }
                    }
                }
                Section("Reconciliation") {
                    Picker("Check for updates", selection: $intervalMinutes) { ForEach(intervals, id: \.self) { Text(intervalLabel($0)).tag($0) } }
                    Toggle("Add new objects", isOn: $addNewItems)
                    Toggle("Update existing statuses", isOn: $updateExistingStates)
                    Picker("State to apply", selection: $fixedState) {
                        Text("Use status from source").tag(ItemState?.none)
                        ForEach(store.statuses) { status in Text(status.name).tag(ItemState?.some(ItemState(rawValue: status.id))) }
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
            .navigationTitle(existingSync == nil ? "New web sync" : "Edit web sync")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(tables.isEmpty || !mapping.contains(.title)) }
            }
            .task { if tables.isEmpty { load() } }
            .alert("Could not read source", isPresented: Binding(get: { errorMessage != nil && tables.isEmpty }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        guard !tables.isEmpty else { return }
        let table = tables[selectedTable]
        if let existingSync {
            existingSync.urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            existingSync.tableName = table.name
            existingSync.headersJSON = (try? String(data: JSONEncoder().encode(table.headers), encoding: .utf8)) ?? "[]"
            existingSync.mappingJSON = (try? String(data: JSONEncoder().encode(mapping.map(\.rawValue)), encoding: .utf8)) ?? "[]"
            existingSync.intervalMinutes = intervalMinutes; existingSync.addNewItems = addNewItems; existingSync.updateExistingStates = updateExistingStates; existingSync.fixedStateRawValue = fixedState?.rawValue; existingSync.tagSeparators = tagSeparators; existingSync.splitTagsOnWhitespace = splitTagsOnWhitespace; existingSync.generateTagsFromTitle = generateTagsFromTitle; existingSync.titleTagModeRawValue = titleTagMode.rawValue; existingSync.titleSeparators = titleSeparators
            store.updateWebSync(existingSync)
        } else {
            store.saveWebSync(WebSyncRecord(collectionID: collectionID, urlString: urlString, tableName: table.name, headers: table.headers, mapping: mapping, intervalMinutes: intervalMinutes, addNewItems: addNewItems, updateExistingStates: updateExistingStates, fixedState: fixedState, tagOptions: tagOptions))
        }
        dismiss()
    }

    private func intervalLabel(_ minutes: Int) -> String {
        if minutes >= 1440 { return "Daily" }
        if minutes >= 60 { return "Every \(minutes / 60) hour\(minutes == 60 ? "" : "s")" }
        return "Every \(minutes) minutes"
    }

    private func load() {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "http" || url.scheme == "https" else { errorMessage = "Enter a valid HTTP(S) URL."; return }
        isLoading = true
        Task {
            do {
                let loaded = try await HTMLImporter().load(url: url)
                await MainActor.run {
                    tables = loaded
                    selectedTable = existingSync.flatMap { sync in loaded.firstIndex { $0.name == sync.tableName } } ?? 0
                    let table = loaded[selectedTable]
                    if let existingSync, existingSync.mapping.count == table.headers.count { mapping = existingSync.mapping } else { mapping = HTMLImporter().suggestMapping(headers: table.headers) }
                    isLoading = false
                }
            } catch { await MainActor.run { errorMessage = error.localizedDescription; isLoading = false } }
        }
    }

    private var tagOptions: TagGenerationOptions {
        var options = TagGenerationOptions()
        options.separators = tagSeparators; options.splitOnWhitespace = splitTagsOnWhitespace; options.generateFromTitle = generateTagsFromTitle; options.titleMode = titleTagMode; options.titleSeparators = titleSeparators
        return options
    }
}
