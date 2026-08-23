import SwiftUI

/// Spreadsheet style editor for a whole collection.
///
/// The card list is optimised for reading a single item at a time. On regular
/// width layouts (iPadOS and macOS) there is enough room to show every item as
/// a row and every field as a column, so the whole collection can be corrected
/// in one pass without opening a sheet per item.
struct CollectionTableView: View {
    @Environment(AppStore.self) private var store
    @State private var drafts: [UUID: CollectionItem] = [:]
    @State private var newItemTitle = ""
    @FocusState private var focusedCell: CellFocus?

    var body: some View {
        let layout = columns
        let width = layout.reduce(0) { $0 + $1.width + Self.cellSpacing } + Self.rowNumberWidth
        VStack(alignment: .leading, spacing: 0) {
            editingBar
            Divider()
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow(columns: layout)
                    Divider()
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(store.visibleItems.enumerated()), id: \.element.id) { index, item in
                                row(for: item, number: index + 1, columns: layout)
                                Divider()
                            }
                            newItemRow(columns: layout)
                        }
                        .frame(width: width, alignment: .leading)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
            .overlay {
                if store.visibleItems.isEmpty {
                    ContentUnavailableView("No items match the filters", systemImage: "tablecells", description: Text("Clear the search or filters to edit the whole collection."))
                        .background(.background)
                }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        // Leaving the table keeps the edits: they are the user's own typing and
        // discarding them silently would be the surprising behaviour.
        .onDisappear { commitAll() }
    }

    // MARK: - Chrome

    private var editingBar: some View {
        HStack(spacing: 12) {
            Label("\(store.visibleItems.count) row\(store.visibleItems.count == 1 ? "" : "s")", systemImage: "tablecells")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !canEdit {
                Label("Read only", systemImage: "lock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pendingChangeCount > 0 {
                Text("\(pendingChangeCount) unsaved change\(pendingChangeCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Button("Revert") { drafts.removeAll() }
                    .buttonStyle(.bordered)
            }
            Button("Save") { commitAll() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(pendingChangeCount == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func headerRow(columns: [SpreadsheetColumn]) -> some View {
        HStack(spacing: Self.cellSpacing) {
            Text("#")
                .frame(width: Self.rowNumberWidth, alignment: .trailing)
            ForEach(columns) { column in
                Group {
                    if let sort = column.sort {
                        Button { store.itemSort = nextSort(for: sort) } label: {
                            HStack(spacing: 4) {
                                Text(column.title)
                                if let symbol = sortIndicator(for: column) { Image(systemName: symbol) }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(column.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(width: column.width, alignment: .leading)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func row(for item: CollectionItem, number: Int, columns: [SpreadsheetColumn]) -> some View {
        let draft = binding(for: item)
        let isChanged = drafts[item.id] != nil
        return HStack(spacing: Self.cellSpacing) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.rowNumberWidth, alignment: .trailing)
            ForEach(columns) { column in
                cell(column: column, item: draft, itemID: item.id)
                    .frame(width: column.width, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isChanged ? Color.accentColor.opacity(0.08) : (number.isMultiple(of: 2) ? Color(uiColor: .secondarySystemBackground).opacity(0.4) : .clear))
        .contextMenu {
            if item.state != .consumed, canEdit {
                Button(role: .destructive) {
                    drafts.removeValue(forKey: item.id)
                    Task { await store.deleteItem(item) }
                } label: { Label("Delete item", systemImage: "trash") }
            }
        }
    }

    private func newItemRow(columns: [SpreadsheetColumn]) -> some View {
        HStack(spacing: Self.cellSpacing) {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Self.rowNumberWidth, alignment: .trailing)
            TextField("Add item…", text: $newItemTitle)
                .textFieldStyle(.plain)
                .onSubmit(addItem)
                .frame(width: columns.first?.width ?? 220, alignment: .leading)
            Button("Add", action: addItem)
                .buttonStyle(.bordered)
                .disabled(newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .disabled(!canEdit)
    }

    // MARK: - Cells

    @ViewBuilder private func cell(column: SpreadsheetColumn, item: Binding<CollectionItem>, itemID: UUID) -> some View {
        let focus = CellFocus(itemID: itemID, columnID: column.id)
        switch column.kind {
        case .title:
            textCell(item.title, focus: focus)
        case .brand:
            textCell(item.brand, focus: focus)
        case .variant:
            textCell(item.variant, focus: focus)
        case .description:
            textCell(item.itemDescription, focus: focus)
        case .status:
            Picker("Status", selection: item.state) {
                ForEach(store.statuses) { status in
                    Label(status.name, systemImage: status.symbol).tag(ItemState(rawValue: status.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!canEdit)
        case .quantity:
            TextField("1", text: Binding(
                get: { "\(item.wrappedValue.quantity)" },
                set: { item.wrappedValue.quantity = max(1, min(999, Int($0.filter(\.isNumber)) ?? 1)) }
            ))
            .textFieldStyle(.plain)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .focused($focusedCell, equals: focus)
            .disabled(!canEdit)
        case .tags:
            textCell(Binding(
                get: { item.wrappedValue.tags.joined(separator: ", ") },
                set: { item.wrappedValue.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
            ), focus: focus)
        case .detail(let key):
            textCell(Binding(
                get: { metadataText(item.wrappedValue.metadata[key]) },
                set: { setMetadata(key: key, value: $0.isEmpty ? nil : .string($0), on: item) }
            ), focus: focus)
        case .metadata(let field):
            metadataCell(field: field, item: item, focus: focus)
        case .updated:
            Text(item.wrappedValue.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func metadataCell(field: MetadataFieldDefinition, item: Binding<CollectionItem>, focus: CellFocus) -> some View {
        let key = field.storageKey
        switch field.type {
        case .text:
            textCell(Binding(
                get: { metadataText(item.wrappedValue.metadata[key]) },
                set: { setMetadata(key: key, value: $0.isEmpty ? nil : .string($0), on: item) }
            ), focus: focus)
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
            .focused($focusedCell, equals: focus)
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

    private func textCell(_ text: Binding<String>, focus: CellFocus) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($focusedCell, equals: focus)
            .disabled(!canEdit)
    }

    // MARK: - Columns

    private var columns: [SpreadsheetColumn] {
        let collection = store.selectedCollection
        var result: [SpreadsheetColumn] = [
            SpreadsheetColumn(id: "title", title: "Title", width: 220, kind: .title, sort: .titleAscending),
            SpreadsheetColumn(id: "brand", title: "Brand", width: 150, kind: .brand),
            SpreadsheetColumn(id: "variant", title: "Variant", width: 150, kind: .variant),
            SpreadsheetColumn(id: "status", title: "Status", width: 160, kind: .status),
            SpreadsheetColumn(id: "quantity", title: "Qty", width: 60, kind: .quantity),
            SpreadsheetColumn(id: "tags", title: "Tags", width: 200, kind: .tags),
            SpreadsheetColumn(id: "description", title: "Description", width: 260, kind: .description)
        ]
        for field in collection?.category.detailFields ?? [] {
            result.append(SpreadsheetColumn(id: "detail.\(field.key)", title: field.title, width: 170, kind: .detail(key: field.key)))
        }
        for field in collection?.metadataFields ?? [] {
            result.append(SpreadsheetColumn(id: field.storageKey, title: field.name, width: width(for: field), kind: .metadata(field), sort: .metadata(fieldID: field.id, direction: .ascending)))
        }
        result.append(SpreadsheetColumn(id: "updated", title: "Updated", width: 170, kind: .updated, sort: .updatedDescending))
        return result
    }

    private func width(for field: MetadataFieldDefinition) -> CGFloat {
        switch field.type {
        case .text: return 180
        case .number: return 110
        case .date: return 170
        case .boolean: return 80
        case .color: return 90
        }
    }

    private func nextSort(for columnSort: ItemSort) -> ItemSort {
        guard case .metadata(let fieldID, _) = columnSort else { return columnSort }
        if case .metadata(fieldID, .ascending) = store.itemSort {
            return .metadata(fieldID: fieldID, direction: .descending)
        }
        return .metadata(fieldID: fieldID, direction: .ascending)
    }

    private func sortIndicator(for column: SpreadsheetColumn) -> String? {
        guard let columnSort = column.sort else { return nil }
        switch (columnSort, store.itemSort) {
        case (.titleAscending, .titleAscending):
            return "chevron.up"
        case (.updatedDescending, .updatedDescending):
            return "chevron.down"
        case (.metadata(let columnField, _), .metadata(let activeField, let direction)) where columnField == activeField:
            return direction == .ascending ? "chevron.up" : "chevron.down"
        default:
            return nil
        }
    }

    // MARK: - Editing

    private var canEdit: Bool { store.selectedCollection?.role.canEdit == true }
    private var pendingChangeCount: Int { drafts.count }

    private func binding(for item: CollectionItem) -> Binding<CollectionItem> {
        Binding(
            get: { drafts[item.id] ?? item },
            set: { updated in
                if updated == item {
                    drafts.removeValue(forKey: item.id)
                } else {
                    drafts[item.id] = updated
                }
            }
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

    private func commitAll() {
        guard canEdit, !drafts.isEmpty else { drafts.removeAll(); return }
        let originals = Dictionary(store.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, draft) in drafts {
            guard let original = originals[id], original != draft else { continue }
            var item = draft
            item.updatedAt = .now
            item.consumedAt = item.state == .consumed ? (original.consumedAt ?? .now) : nil
            store.updateItem(item, previousState: original.state)
        }
        drafts.removeAll()
    }

    private func addItem() {
        let title = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit, !title.isEmpty else { return }
        store.addItem(title: title, brand: "", variant: "", description: "", state: store.statuses.first.map { ItemState(rawValue: $0.id) } ?? .wanted, quantity: 1, tags: [])
        newItemTitle = ""
    }

    private static let cellSpacing: CGFloat = 12
    private static let rowNumberWidth: CGFloat = 34

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

private struct CellFocus: Hashable {
    let itemID: UUID
    let columnID: String
}

private struct SpreadsheetColumn: Identifiable {
    enum Kind {
        case title, brand, variant, description, status, quantity, tags, updated
        case detail(key: String)
        case metadata(MetadataFieldDefinition)
    }

    let id: String
    let title: String
    let width: CGFloat
    let kind: Kind
    var sort: ItemSort?
}
