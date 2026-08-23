import SwiftUI
import UniformTypeIdentifiers

struct CollectionDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("collection.layout.usesTable") private var prefersTableLayout = false
    @State private var showingAddItem = false; @State private var showingBulkEdit = false; @State private var showingTagManager = false; @State private var showingDeleteAllConfirmation = false
    @State private var showingImporter = false; @State private var showingHTMLImporter = false; @State private var showingWebSync = false; @State private var showingEditCollection = false; @State private var showingSharing = false; @State private var csvImportTable: CSVImportTable?; @State private var csvImportError: String?; @State private var isImporting = false
    @State private var showingSyncError = false
    var body: some View {
        @Bindable var store = store
        Group { if showsTableLayout { tableLayout } else { cardLayout } }
            .refreshable { await store.syncCollections() }
            .background(Color(uiColor: .systemGroupedBackground)).navigationTitle(store.selectedCollection?.name ?? "Collection").navigationBarTitleDisplayMode(.inline).searchable(text: $store.searchText, prompt: "Search items, metadata, tags…")
            .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { if horizontalSizeClass == .regular { layoutPicker }; Menu { Button { showingAddItem = true } label: { Label("Add item", systemImage: "plus") }; Button { showingImporter = true } label: { Label("Import CSV", systemImage: "square.and.arrow.down") }; Button { showingHTMLImporter = true } label: { Label("Import web / HTML", systemImage: "globe") }; Button { showingWebSync = true } label: { Label("Background web sync", systemImage: "arrow.triangle.2.circlepath") }; Button { showingTagManager = true } label: { Label("Manage tags", systemImage: "tag") }; Button(role: .destructive) { showingDeleteAllConfirmation = true } label: { Label("Delete all items", systemImage: "trash") }; Divider(); Button { showingEditCollection = true } label: { Label("Edit collection", systemImage: "pencil") }; Button { showingSharing = true } label: { Label("Share collection", systemImage: "person.2") } } label: { Image(systemName: "ellipsis.circle") }.buttonStyle(.bordered); Button { showingAddItem = true } label: { Label("Add item", systemImage: "plus") }.buttonStyle(.borderedProminent) } }
            .sheet(isPresented: $showingAddItem) { AddItemView() }
            .sheet(isPresented: $showingBulkEdit) { BulkEditItemsView(items: store.visibleItems) }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.commaSeparatedText, .text], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                isImporting = true
                Task {
                    let parsed = await Task.detached(priority: .userInitiated) {
                        guard url.startAccessingSecurityScopedResource() else { return (table: CSVImportTable?.none, error: String?.some("The selected file could not be accessed.")) }
                        defer { url.stopAccessingSecurityScopedResource() }
                        do {
                            let table = try CollectionImporter().parseTable(Data(contentsOf: url))
                            guard !table.headers.isEmpty else { return (table: CSVImportTable?.none, error: String?.some("The CSV file does not contain a header row.")) }
                            return (table: CSVImportTable?.some(table), error: String?.none)
                        } catch {
                            return (table: CSVImportTable?.none, error: String?.some(error.localizedDescription))
                        }
                    }.value
                    isImporting = false
                    csvImportTable = parsed.table
                    csvImportError = parsed.error
                }
            }
            .sheet(item: $csvImportTable) { table in CSVMappingView(table: table) }
            .sheet(isPresented: $showingHTMLImporter) { HTMLImportView() }
            .sheet(isPresented: $showingWebSync) { WebSyncListView() }
            .sheet(isPresented: $showingTagManager) { if let collection = store.selectedCollection { TagManagementView(collection: collection) } }
            .sheet(isPresented: $showingEditCollection) { if let collection = store.selectedCollection { EditCollectionView(collection: collection) } }
            .sheet(isPresented: $showingSharing) { if let collection = store.selectedCollection { CloudSharingView(collection: collection) } }
            .confirmationDialog("Delete all items in this collection? This cannot be undone.", isPresented: $showingDeleteAllConfirmation, titleVisibility: .visible) {
                Button("Delete All Items", role: .destructive) { Task { _ = await store.deleteAllItems() } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("iCloud sync error", isPresented: $showingSyncError) {
                Button("Retry") { Task { await store.syncCollections() } }
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.syncError ?? "The sync error is no longer active.")
            }
            .alert("CSV import failed", isPresented: Binding(get: { csvImportError != nil }, set: { if !$0 { csvImportError = nil } })) {
                Button("OK") { csvImportError = nil }
            } message: {
                Text(csvImportError ?? "The file could not be read.")
            }
    }
    // The spreadsheet layout needs the full width of a regular size class to
    // be useful, so compact layouts (iPhone, slide over) keep the card list.
    private var showsTableLayout: Bool { horizontalSizeClass == .regular && prefersTableLayout }

    private var cardLayout: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) { header; syncBanner; stats; filterBar; progressBanners; LazyVStack(spacing: 12) { ForEach(store.visibleItems) { ItemCard(item: $0) } } }.padding(.horizontal).padding(.bottom, 24) }
    }

    private var tableLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            syncBanner
            // The filter bar scrolls horizontally, so it has to be pinned to
            // its intrinsic height or it competes with the table for space.
            filterBar.fixedSize(horizontal: false, vertical: true)
            progressBanners
            CollectionTableView()
        }
        .padding(.horizontal)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var progressBanners: some View {
        if store.isBulkOperationInProgress { ProgressView("Deleting items…").frame(maxWidth: .infinity).padding() }
        if isImporting { ProgressView("Reading import…").frame(maxWidth: .infinity).padding() }
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: $prefersTableLayout) {
            Label("Cards", systemImage: "square.grid.2x2").tag(false)
            Label("Table", systemImage: "tablecells").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 120)
        .help("Switch between the card list and the editable table")
    }

    private var header: some View { HStack { VStack(alignment: .leading, spacing: 4) { Text("Your shared shelf").font(.title2.bold()); Text("Everything you want to remember, together.").foregroundStyle(.secondary) }; Spacer(); Image(systemName: store.selectedCollection?.icon ?? "square.stack").font(.system(size: 32)).foregroundStyle(.pink).padding(14).background(.pink.opacity(0.12), in: .circle) } }
    private var syncBanner: some View { Group { if store.syncState == .syncing { Label("Syncing collaboration changes…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary) } else if let error = store.syncError { HStack { Button { showingSyncError = true } label: { Label("Sync needs attention", systemImage: "exclamationmark.icloud") }.buttonStyle(.plain); Spacer(); Button("Retry") { Task { await store.syncCollections() } } }.font(.footnote).foregroundStyle(.orange).help(error) } else if store.syncState == .idle { Label("Changes are saved to iCloud", systemImage: "checkmark.icloud").font(.footnote).foregroundStyle(.secondary) } } }
    private var stats: some View { let s = store.stats; return HStack(spacing: 10) { StatTile(value: s.stored, label: "In storage", color: .teal); StatTile(value: s.consumed, label: "Consumed", color: .green); StatTile(value: s.wanted, label: "Want to try", color: .orange) } }
    private var filterBar: some View {
        @Bindable var store = store
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                FilterChip(title: "All", isSelected: store.selectedState == nil) { store.selectedState = nil }
                ForEach(store.statuses) { status in
                    let state = ItemState(rawValue: status.id)
                    FilterChip(title: status.name, icon: status.symbol, isSelected: store.selectedState == state) {
                        store.selectedState = store.selectedState == state ? nil : state
                    }
                    .tint(status.color.color)
                }
                Menu {
                    Button("All brands") { store.selectedBrand = nil }
                    ForEach(store.brands, id: \.self) { brand in
                        Button(brand) { store.selectedBrand = brand }
                    }
                } label: {
                    Label(store.selectedBrand ?? "Brand", systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.bordered)
                Menu {
                    ForEach(ItemSort.builtInCases.filter { $0 == .updatedDescending || $0 == .titleAscending || store.hasDateTags }, id: \.self) { sort in
                        Button { store.itemSort = sort } label: {
                            if store.itemSort == sort {
                                Label(sort.label, systemImage: "checkmark")
                            } else {
                                Text(sort.label)
                            }
                        }
                    }
                    if let fields = store.selectedCollection?.metadataFields, !fields.isEmpty {
                        Divider()
                        ForEach(fields) { field in
                            Menu {
                                ForEach(SortDirection.allCases) { direction in
                                    let sort = ItemSort.metadata(fieldID: field.id, direction: direction)
                                    Button { store.itemSort = sort } label: {
                                        if store.itemSort == sort {
                                            Label(direction.label, systemImage: "checkmark")
                                        } else {
                                            Text(direction.label)
                                        }
                                    }
                                }
                            } label: {
                                Label(field.name, systemImage: field.type.symbol)
                            }
                        }
                    }
                } label: {
                    Label(store.itemSortLabel, systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
                Button { showingBulkEdit = true } label: {
                    Label("Edit \(store.visibleItems.count) items", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.visibleItems.isEmpty || store.selectedCollection?.role.canEdit != true)
            }
        }
    }
}

struct StatTile: View { let value: Int; let label: String; let color: Color; var body: some View { VStack(alignment: .leading, spacing: 5) { Text("\(value)").font(.title.bold()).foregroundStyle(color); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.background, in: RoundedRectangle(cornerRadius: 16)) } }
struct FilterChip: View { let title: String; var icon: String?; let isSelected: Bool; let action: () -> Void; var body: some View { Button(action: action) { HStack(spacing: 5) { if let icon { Image(systemName: icon) }; Text(title) } }.buttonStyle(.bordered).tint(isSelected ? .accentColor : .secondary).background(isSelected ? Color.accentColor.opacity(0.1) : .clear, in: Capsule()) } }
