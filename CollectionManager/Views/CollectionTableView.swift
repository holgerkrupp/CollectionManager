import SwiftUI
import TipKit

/// Spreadsheet style editor for a whole collection.
///
/// The card list is optimised for reading a single item at a time. On regular
/// width layouts (iPadOS and macOS) there is enough room to show every item as
/// a row and every field as a column, so the whole collection can be corrected
/// in one pass without opening a sheet per item.
struct CollectionTableView: View {
    @Environment(AppStore.self) private var store
    @Bindable var editSession: CollectionEditSession
    @State private var selection: Set<UUID> = []
    @State private var sortOrder: [KeyPathComparator<CollectionItem>] = [KeyPathComparator(\.updatedAt, order: .reverse)]
    // The filter bar and the column headers are two ways to order the same
    // rows, so whichever the user touched last wins.
    @State private var usesColumnSort = false
    @State private var sortedRowsCache: CollectionTableSortCache?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            editingBar
            Divider()
            table
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView("No items match the filters", systemImage: "tablecells", description: Text("Clear the search or filters to edit the whole collection."))
                            .background(.background)
                    }
                }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: sortOrder) { _, _ in usesColumnSort = true }
        .onChange(of: store.itemSort) { _, _ in usesColumnSort = false }
        .task(id: sortIdentity) {
            let identity = sortIdentity
            guard !Task.isCancelled else { return }
            guard identity.usesColumnSort else { sortedRowsCache = nil; return }
            let snapshot = store.visibleItems
            let worker = Task.detached(priority: .userInitiated) {
                try CollectionTableSort.sorted(snapshot, using: identity.sortOrder)
            }
            do {
                let sorted = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, sortIdentity == identity else { return }
                sortedRowsCache = CollectionTableSortCache(identity: identity, sortedRows: sorted)
            } catch {
                // The current store rows remain visible until a current header
                // sort completes. Canceled/obsolete work never publishes rows.
            }
        }
        // The AppStore-owned session outlives either adaptive representation.
    }

    private var sortIdentity: CollectionTableSortIdentity {
        CollectionTableSortIdentity(visibleItemsRevision: store.visibleItemsRevision,
                                    sortOrder: sortOrder, usesColumnSort: usesColumnSort,
                                    collectionID: editSession.collectionID)
    }

    private var rows: [CollectionItem] {
        sortedRowsCache?.rows(for: sortIdentity, fallback: store.visibleItems) ?? store.visibleItems
    }

    // MARK: - Table

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { item in titleCell(item) }
                .width(min: 160, ideal: 240)
            TableColumn("Brand", value: \.brand) { item in
                textCell(binding(for: item).brand)
            }
            .width(min: 90, ideal: 150)
            TableColumn("Variant", value: \.variant) { item in
                textCell(binding(for: item).variant)
            }
            .width(min: 90, ideal: 150)
            TableColumn("Status", value: \.state.rawValue) { item in statusCell(item) }
                .width(min: 120, ideal: 160)
            TableColumn("Qty", value: \.quantity) { item in quantityCell(item) }
                .width(min: 44, ideal: 60)
            TableColumn("Tags") { item in tagsCell(item) }
                .width(min: 110, ideal: 200)
            TableColumn("Description", value: \.itemDescription) { item in
                textCell(binding(for: item).itemDescription)
            }
            .width(min: 140, ideal: 260)
            TableColumnForEach(detailColumns, id: \.id) { column in
                TableColumn(column.title) { item in
                    detailCell(key: column.key, placeholder: column.placeholder, item: binding(for: item))
                }
                .width(min: 110, ideal: 170)
            }
            TableColumnForEach(metadataFields, id: \.id) { field in
                TableColumn(field.name) { item in
                    metadataCell(field: field, item: binding(for: item))
                }
                .width(min: 70, ideal: idealWidth(for: field))
            }
            TableColumn("Updated", value: \.updatedAt) { item in
                Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 170)
        }
        .contextMenu(forSelectionType: CollectionItem.ID.self) { ids in
            if canEdit {
                Button(role: .destructive) { deleteItems(ids: ids) } label: {
                    Label(ids.count > 1 ? "Delete \(ids.count) items" : "Delete item", systemImage: "trash")
                }
                .disabled(deletableItems(ids: ids).isEmpty)
            }
        }
    }

    // MARK: - Chrome

    private var editingBar: some View {
        HStack(spacing: 12) {
            Label("Rows: \(rows.count)", systemImage: "tablecells")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !canEdit {
                Label("Read only", systemImage: "lock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if canEdit {
                TextField("Add item…", text: $editSession.newItemTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(addItem)
                Button("Add", action: addItem)
                    .buttonStyle(.bordered)
                    .disabled(editSession.newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer()
            if canEdit, !selection.isEmpty {
                Menu {
                    ForEach(store.statuses) { status in
                        Button { applyStatus(ItemState(rawValue: status.id)) } label: {
                            Label(status.name, systemImage: status.symbol)
                        }
                    }
                } label: {
                    Label("Status of \(selection.count) selected", systemImage: "checklist")
                }
                .buttonStyle(.bordered)
                .help("Set one status for all selected rows")
            }
            if pendingChangeCount > 0 {
                Text("Unsaved changes: \(pendingChangeCount)")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Button("Revert") { editSession.revert() }
                    .buttonStyle(.bordered)
                    .help("Discard the edits you haven’t saved")
            }
            Button("Save") { commitAll() }
                .buttonStyle(.borderedProminent)
                .help("Save the edits in every changed row")
                .keyboardShortcut("s", modifiers: .command)
                .disabled(pendingChangeCount == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Cells

    private func titleCell(_ item: CollectionItem) -> some View {
        HStack(spacing: 6) {
            textCell(binding(for: item).title)
            if editSession.drafts[item.id] != nil {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Unsaved changes")
            }
        }
    }

    private func statusCell(_ item: CollectionItem) -> some View {
        Picker("Status", selection: binding(for: item).state) {
            ForEach(store.statuses) { status in
                Label(status.name, systemImage: status.symbol).tag(ItemState(rawValue: status.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(!canEdit)
    }

    private func quantityCell(_ item: CollectionItem) -> some View {
        let draft = binding(for: item)
        return TextField("1", text: Binding(
            get: { "\(draft.wrappedValue.quantity)" },
            set: { draft.wrappedValue.quantity = max(1, min(999, Int($0.filter(\.isNumber)) ?? 1)) }
        ))
        .textFieldStyle(.plain)
        #if os(iOS)
        .keyboardType(.numberPad)
        #endif
        .multilineTextAlignment(.trailing)
        .disabled(!canEdit)
    }

    private func tagsCell(_ item: CollectionItem) -> some View {
        let draft = binding(for: item)
        return textCell(Binding(
            get: { draft.wrappedValue.tags.joined(separator: ", ") },
            set: { draft.wrappedValue.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        ))
    }

    private func detailCell(key: String, placeholder: String, item: Binding<CollectionItem>) -> some View {
        TextField(placeholder, text: Binding(
            get: { metadataText(item.wrappedValue.metadata[key]) },
            set: { setMetadata(key: key, value: $0.isEmpty ? nil : .string($0), on: item) }
        ))
        .textFieldStyle(.plain)
        .lineLimit(1)
        .disabled(!canEdit)
    }

    @ViewBuilder private func metadataCell(field: MetadataFieldDefinition, item: Binding<CollectionItem>) -> some View {
        let key = field.storageKey
        switch field.type {
        case .text:
            textCell(Binding(
                get: { metadataText(item.wrappedValue.metadata[key]) },
                set: { setMetadata(key: key, value: $0.isEmpty ? nil : .string($0), on: item) }
            ))
        case .number:
            TextField(field.name, text: Binding(
                get: { metadataText(item.wrappedValue.metadata[key]) },
                set: { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        setMetadata(key: key, value: nil, on: item)
                    } else if let number = Self.numberFormatter.number(from: trimmed) {
                        setMetadata(key: key, value: .decimal(number.doubleValue), on: item)
                    } else {
                        setMetadata(key: key, value: .string(trimmed), on: item)
                    }
                }
            ))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .disabled(!canEdit)
        case .date:
            HStack(spacing: 4) {
                if case .date(let date)? = item.wrappedValue.metadata[key] {
                    DatePicker(field.name, selection: Binding(
                        get: { date },
                        set: { setMetadata(key: key, value: .date($0), on: item) }
                    ), displayedComponents: .date)
                    .labelsHidden()
                    Button { setMetadata(key: key, value: nil, on: item) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear \(field.name)")
                } else {
                    Button("Set date") { setMetadata(key: key, value: .date(.now), on: item) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .disabled(!canEdit)
        case .boolean:
            Toggle(field.name, isOn: Binding(
                get: { Self.booleanValue(for: item.wrappedValue.metadata[key]) ?? false },
                set: { setMetadata(key: key, value: .boolean($0), on: item) }
            ))
            .labelsHidden()
            .disabled(!canEdit)
        case .color:
            HStack(spacing: 4) {
                ColorPicker(field.name, selection: Binding(
                    get: { MetadataColorCodec.color(from: item.wrappedValue.metadata[key]) ?? .accentColor },
                    set: { setMetadata(key: key, value: .string(MetadataColorCodec.hex(from: $0)), on: item) }
                ), supportsOpacity: false)
                .labelsHidden()
                if item.wrappedValue.metadata[key] != nil {
                    Button { setMetadata(key: key, value: nil, on: item) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear \(field.name)")
                }
            }
            .disabled(!canEdit)
        }
    }

    private func textCell(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .disabled(!canEdit)
    }

    // MARK: - Columns

    private var detailColumns: [DetailColumn] {
        (store.selectedCollection?.category.detailFields ?? []).map {
            DetailColumn(key: $0.key, title: $0.title, placeholder: $0.placeholder)
        }
    }

    private var metadataFields: [MetadataFieldDefinition] { store.selectedCollection?.metadataFields ?? [] }

    private func idealWidth(for field: MetadataFieldDefinition) -> CGFloat {
        switch field.type {
        case .text: return 180
        case .number: return 110
        case .date: return 170
        case .boolean: return 80
        case .color: return 90
        }
    }

    // MARK: - Editing

    private var canEdit: Bool { store.selectedCollection?.role.canEdit == true }
    private var pendingChangeCount: Int { editSession.pendingChangeCount }

    private func binding(for item: CollectionItem) -> Binding<CollectionItem> {
        Binding(
            get: { editSession.value(for: item) },
            set: { editSession.set($0, original: item) }
        )
    }

    private func setMetadata(key: String, value: MetadataValue?, on item: Binding<CollectionItem>) {
        if let value {
            item.wrappedValue.metadata[key] = value
        } else {
            item.wrappedValue.metadata.removeValue(forKey: key)
        }
    }

    private func metadataText(_ value: MetadataValue?) -> String {
        guard let value else { return "" }
        if case .string(let text) = value { return text }
        return value.displayValue
    }

    @discardableResult private func commitAll() -> Bool {
        editSession.save(originals: store.items, canEdit: canEdit) { item, previousState in
            store.updateItem(item, previousState: previousState)
        }
    }

    private func addItem() {
        let title = editSession.newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit, !title.isEmpty else { return }
        if store.addItem(title: title, brand: "", variant: "", description: "", state: store.selectedCollection.map { ItemState(rawValue: $0.defaultStatusID) } ?? store.statuses.first.map { ItemState(rawValue: $0.id) } ?? .wanted, quantity: 1, tags: []) != nil {
            AppTips.itemAdded.sendDonation()
            editSession.newItemTitle = ""
        }
    }

    private func applyStatus(_ state: ItemState) {
        // Changing selected row status is another draft edit, not an implicit
        // save of every unrelated cell in the table.
        for original in store.items where selection.contains(original.id) {
            var draft = editSession.value(for: original)
            draft.state = state
            editSession.set(draft, original: original)
        }
    }

    private func deletableItems(ids: Set<CollectionItem.ID>) -> [CollectionItem] {
        store.items.filter { ids.contains($0.id) }
    }

    private func deleteItems(ids: Set<CollectionItem.ID>) {
        let targets = deletableItems(ids: ids)
        Task {
            for item in targets {
                if await store.deleteItem(item) {
                    editSession.didDelete(item.id)
                    selection.remove(item.id)
                }
            }
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.maximumFractionDigits = 16
        return formatter
    }()

    private static func booleanValue(for value: MetadataValue?) -> Bool? {
        switch value {
        case .boolean(let boolean): return boolean
        case .integer(let number): return number != 0
        case .decimal(let number): return number != 0
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y", "1", "on": return true
            case "false", "no", "n", "0", "off": return false
            default: return nil
            }
        default: return nil
        }
    }
}

private struct DetailColumn: Identifiable {
    let key: String
    let title: String
    let placeholder: String

    var id: String { key }
}
