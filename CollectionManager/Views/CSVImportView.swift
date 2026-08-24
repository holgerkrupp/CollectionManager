import SwiftUI

/// The CSV import screen. It deliberately shows the file the way a spreadsheet
/// would — one row per source column, with real example values next to the
/// field each column will land in — because the previous list of bare pickers
/// gave no way to tell which column was being mapped.
struct CSVImportView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let file: CSVParsedFile

    @State private var delimiter: CSVDelimiter
    @State private var firstRowIsHeader: Bool
    @State private var table = CSVImportTable(headers: [], rows: [])
    @State private var mapping: [ImportColumnDestination] = []
    @State private var newFieldNames: [Int: String] = [:]
    /// Columns that make up the item name. A column can be listed here and still
    /// be mapped to a field of its own, so "color" can be part of the title and
    /// remain a color field.
    @State private var titleColumns: Set<Int> = []
    @State private var conditionalRules: [ConditionalMappingRule] = []
    @State private var showingAdvanced = false
    @State private var allowsDuplicates = false
    @State private var preparation: ImportPreparation?

    private let importer = CollectionImporter()

    init(file: CSVParsedFile) {
        self.file = file
        _delimiter = State(initialValue: file.detectedDelimiter)
        _firstRowIsHeader = State(initialValue: file.suggestsHeaderRow)
    }

    private var metadataFields: [MetadataFieldDefinition] { store.selectedCollection?.metadataFields ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fileCard
                    previewCard
                    summaryCard
                    columnsCard
                    advancedCard
                }
                .padding()
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle("Import CSV")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(importButtonTitle) { prepareReview() }
                        .disabled(!canContinue)
                }
            }
            .onAppear { rebuildTable(resuggestMapping: true) }
            .onChange(of: delimiter) { rebuildTable(resuggestMapping: true) }
            .onChange(of: firstRowIsHeader) { rebuildTable(resuggestMapping: true) }
            .sheet(item: $preparation) { preparation in
                ImportReviewView(
                    drafts: preparation.drafts,
                    metadataFieldsToCreate: preparation.newMetadataFields,
                    metadataFields: preparation.metadataFields,
                    allowsDuplicates: allowsDuplicates,
                    onImport: { dismiss() }
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 560)
        #endif
    }

    // MARK: - File

    private var fileCard: some View {
        ImportCard(title: "File", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 12) {
                Text(file.fileName)
                    .font(.headline)
                Text("\(table.rows.count) data \(table.rows.count == 1 ? "row" : "rows") · \(table.headers.count) \(table.headers.count == 1 ? "column" : "columns")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle(isOn: $firstRowIsHeader) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("First row contains column names")
                        Text(firstRowIsHeader ? "The first row is used as the column names and is not imported." : "Every row is imported. Columns are numbered instead of named.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Separator", selection: $delimiter) {
                    ForEach(CSVDelimiter.allCases) { option in
                        Text(option.label + (option == file.detectedDelimiter ? "  (detected)" : "")).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - Preview

    private var previewCard: some View {
        ImportCard(title: "Preview", systemImage: "tablecells") {
            if table.headers.isEmpty {
                Text("No columns were found. Try a different separator.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        previewRow(values: table.headers, isHeader: true)
                        ForEach(Array(table.rows.prefix(4).enumerated()), id: \.offset) { _, row in
                            Divider()
                            previewRow(values: row, isHeader: false)
                        }
                    }
                }
                if table.rows.count > 4 {
                    Text("Showing the first 4 of \(table.rows.count) rows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func previewRow(values: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack(alignment: .leading, spacing: 3) {
                    Text(value.isEmpty ? "—" : value)
                        .font(isHeader ? .caption.bold() : .caption)
                        .foregroundStyle(isHeader ? .primary : .secondary)
                        .lineLimit(1)
                    if isHeader {
                        Text(previewDestinationLabel(at: index))
                            .font(.caption2)
                            .foregroundStyle(isIgnored(index) ? Color.secondary : Color.accentColor)
                            .lineLimit(1)
                    }
                }
                .frame(width: 130, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .opacity(isIgnored(index) ? 0.45 : 1)
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        ImportCard(title: "Result", systemImage: "checklist") {
            VStack(alignment: .leading, spacing: 8) {
                if !hasTitleColumn {
                    Label("Pick the column that holds the item name and assign it to “Title”. It is the only required field.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                } else {
                    Label("\(importableRowCount) \(importableRowCount == 1 ? "item" : "items") will be created.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                }
                if hasTitleColumn {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titleSourceDescription)
                            .font(.subheadline)
                        if let example = exampleTitle {
                            Text("First item: “\(example)”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Switch on “Also use in the item title” for any column to add it to the name. Those columns still fill their own field as well.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if duplicateTitleCount > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(duplicateTitleCount) \(duplicateTitleCount == 1 ? "row repeats" : "rows repeat") a title, brand and variant that another row or an existing item already uses.", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        Toggle("Import repeated rows anyway", isOn: $allowsDuplicates)
                            .font(.subheadline)
                        Text(allowsDuplicates ? "Every row becomes its own item." : "Repeated rows are skipped. Add more columns to the Title to tell them apart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !newFieldSummaries.isEmpty {
                    Label("New custom fields: \(newFieldSummaries.joined(separator: ", "))", systemImage: "plus.square.on.square")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if ignoredColumnCount > 0 {
                    Label("\(ignoredColumnCount) \(ignoredColumnCount == 1 ? "column is" : "columns are") not imported.", systemImage: "minus.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let duplicate = duplicateNewFieldName {
                    Label("Two new fields are both named “\(duplicate)”. They will be created as separate fields.", systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Columns

    private var columnsCard: some View {
        ImportCard(title: "Columns", systemImage: "arrow.left.arrow.right") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Choose where each column of the file goes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to suggestions") { rebuildTable(resuggestMapping: true) }
                        .font(.subheadline)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.bottom, 4)

                ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
                    Divider().padding(.vertical, 10)
                    columnRow(index: index, header: header)
                }
            }
        }
    }

    private func columnRow(index: Int, header: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(header)
                            .font(.headline)
                        if let part = titlePartNumber(at: index), destination(at: index) != .standard(.title) {
                            Text("Title part \(part)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(examplesText(for: index))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                destinationMenu(index: index)
            }

            Toggle(isOn: titleParticipation(at: index)) {
                Text(destination(at: index) == .standard(.title) ? "Use in the item title" : "Also use in the item title")
                    .font(.subheadline)
            }
            .platformCheckboxToggle()

            if case .newMetadata(let type) = destination(at: index) {
                newFieldEditor(index: index, type: type, header: header)
            }
        }
        .opacity(isIgnored(index) && !titleColumns.contains(index) ? 0.55 : 1)
    }

    private func destinationMenu(index: Int) -> some View {
        Menu {
            Button { setMapping(.ignore, at: index) } label: { Label("Don't import", systemImage: "minus.circle") }

            Section("Item fields") {
                ForEach(HTMLImportField.allCases.filter { $0 != .ignore }) { field in
                    Button { setMapping(.standard(field), at: index) } label: {
                        Label(field.label + (field == .title ? " (required)" : ""), systemImage: symbol(for: field))
                    }
                }
            }

            if !metadataFields.isEmpty {
                Section("Existing custom fields") {
                    ForEach(metadataFields) { field in
                        Button { setMapping(.existingMetadata(field.id), at: index) } label: {
                            Label(field.name, systemImage: field.type.symbol)
                        }
                    }
                }
            }

            Section("Create a new custom field") {
                ForEach(MetadataFieldType.allCases) { type in
                    Button { setMapping(.newMetadata(type), at: index) } label: {
                        Label("New \(type.label) field", systemImage: type.symbol)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: destinationSymbol(at: index))
                Text(shortDestinationLabel(at: index))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .frame(minWidth: 150)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
    }

    private func newFieldEditor(index: Int, type: MetadataFieldType, header: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Field name", text: newFieldNameBinding(at: index, header: header))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Type")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Type", selection: newFieldTypeBinding(at: index)) {
                    ForEach(MetadataFieldType.allCases) { option in
                        Label(option.label, systemImage: option.symbol).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
                if let suggested = suggestedType(at: index), suggested != type {
                    Button("Use \(suggested.label)") { setMapping(.newMetadata(suggested), at: index) }
                        .font(.caption)
                }
            }
            if let warning = conversionWarning(at: index, type: type) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color.platformGroupedBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Advanced

    private var advancedCard: some View {
        ImportCard(title: "Advanced", systemImage: "slider.horizontal.3") {
            DisclosureGroup(isExpanded: $showingAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Conditional rules set a status or a custom field when a column has a specific value, for example when an “Owned?” column says TRUE.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach($conditionalRules) { $rule in
                        ConditionalRuleRow(
                            headers: table.headers,
                            statuses: store.statuses,
                            metadataFields: metadataFields,
                            rule: $rule,
                            onDelete: { conditionalRules.removeAll { $0.id == rule.id } }
                        )
                    }
                    Button {
                        if let header = table.headers.first, let status = store.statuses.first {
                            conditionalRules.append(ConditionalMappingRule(sourceColumn: header, equalsValue: "", action: .status(status.id)))
                        }
                    } label: {
                        Label("Add rule", systemImage: "plus.circle")
                    }
                    .disabled(table.headers.isEmpty || store.statuses.isEmpty)
                }
                .padding(.top, 8)
            } label: {
                Text("Conditional rules\(conditionalRules.isEmpty ? "" : " (\(conditionalRules.count))")")
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Derived state

    private func destination(at index: Int) -> ImportColumnDestination {
        mapping.indices.contains(index) ? mapping[index] : .ignore
    }

    private func isIgnored(_ index: Int) -> Bool { destination(at: index) == .ignore }

    private var hasTitleColumn: Bool { !titleColumnIndices.isEmpty }

    private var canContinue: Bool { hasTitleColumn && importableRowCount > 0 }

    private var importButtonTitle: String {
        hasTitleColumn ? "Review \(importableRowCount)" : "Review"
    }

    private var importableRowCount: Int {
        guard hasTitleColumn else { return 0 }
        return table.rows.filter { !composedTitle(for: $0).isEmpty }.count
    }

    private var titleColumnIndices: [Int] {
        titleColumns.filter { table.headers.indices.contains($0) }.sorted()
    }

    private func titlePartNumber(at index: Int) -> Int? {
        titleColumnIndices.firstIndex(of: index).map { $0 + 1 }
    }

    private func titleParticipation(at index: Int) -> Binding<Bool> {
        Binding(
            get: { titleColumns.contains(index) },
            set: { isOn in
                if isOn {
                    titleColumns.insert(index)
                    // A column that had no destination becomes a title-only column.
                    if destination(at: index) == .ignore, mapping.indices.contains(index) { mapping[index] = .standard(.title) }
                } else {
                    titleColumns.remove(index)
                    if destination(at: index) == .standard(.title), mapping.indices.contains(index) { mapping[index] = .ignore }
                }
            }
        )
    }

    private var titleSourceDescription: String {
        let names = titleColumnIndices.compactMap { table.headers.indices.contains($0) ? table.headers[$0] : nil }
        guard !names.isEmpty else { return "" }
        return names.count == 1 ? "Title comes from “\(names[0])”." : "Title combines " + names.map { "“\($0)”" }.joined(separator: " + ") + "."
    }

    private func composedTitle(for row: [String]) -> String {
        titleColumnIndices.compactMap { index in
            let value = index < row.count ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return value.isEmpty ? nil : value
        }.joined(separator: " ")
    }

    private var exampleTitle: String? {
        table.rows.lazy.map(composedTitle(for:)).first { !$0.isEmpty }
    }

    /// Items are identified by title, brand and variant, so rows that share all
    /// three collapse into one item unless duplicates are explicitly allowed.
    private var duplicateTitleCount: Int {
        guard hasTitleColumn else { return 0 }
        let brandIndex = mapping.firstIndex(of: .standard(.brand))
        let variantIndex = mapping.firstIndex(of: .standard(.variant))
        func part(_ index: Int?, _ row: [String]) -> String {
            guard let index, index < row.count else { return "" }
            return row[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var seen = Set(store.items.map { "\($0.title.lowercased())|\($0.brand.lowercased())|\($0.variant.lowercased())" })
        var repeats = 0
        for row in table.rows {
            let title = composedTitle(for: row)
            guard !title.isEmpty else { continue }
            let key = "\(title.lowercased())|\(part(brandIndex, row))|\(part(variantIndex, row))"
            if !seen.insert(key).inserted { repeats += 1 }
        }
        return repeats
    }

    private var ignoredColumnCount: Int {
        table.headers.indices.filter { isIgnored($0) }.count
    }

    private var newFieldSummaries: [String] {
        table.headers.indices.compactMap { index in
            guard case .newMetadata(let type) = destination(at: index) else { return nil }
            return "\(resolvedNewFieldName(at: index)) (\(type.label.lowercased()))"
        }
    }

    private var duplicateNewFieldName: String? {
        var seen = Set<String>()
        for index in table.headers.indices {
            guard case .newMetadata = destination(at: index) else { continue }
            let name = resolvedNewFieldName(at: index).lowercased()
            if !seen.insert(name).inserted { return resolvedNewFieldName(at: index) }
        }
        return nil
    }

    private func resolvedNewFieldName(at index: Int) -> String {
        let custom = newFieldNames[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let header = table.headers.indices.contains(index) ? table.headers[index] : ""
        return header.isEmpty ? "Column \(index + 1)" : header
    }

    private func values(at index: Int) -> [String] {
        table.rows.compactMap { index < $0.count ? $0[index].trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            .filter { !$0.isEmpty }
    }

    private func examplesText(for index: Int) -> String {
        let examples = values(at: index)
        guard !examples.isEmpty else { return "No values in this column" }
        return "e.g. " + examples.prefix(3).joined(separator: " · ")
    }

    private func suggestedType(at index: Int) -> MetadataFieldType? {
        let suggestion = importer.suggestMapping(for: CSVImportTable(headers: [table.headers.indices.contains(index) ? table.headers[index] : ""], rows: table.rows.map { index < $0.count ? [$0[index]] : [""] }), existingMetadataFields: [])
        guard case .newMetadata(let type) = suggestion.first else { return nil }
        return type
    }

    /// Warns when the chosen type would silently drop values, which is easy to
    /// cause by forcing a text column to Number or Date.
    private func conversionWarning(at index: Int, type: MetadataFieldType) -> String? {
        guard type == .number || type == .date || type == .boolean else { return nil }
        let all = values(at: index)
        guard !all.isEmpty else { return nil }
        let unreadable = all.filter { value in
            switch type {
            case .number: Double(value.replacingOccurrences(of: ",", with: ".")) == nil
            case .date: MetadataDateParser.parse(value, hint: table.headers.indices.contains(index) ? table.headers[index] : "") == nil
            case .boolean: !["true", "yes", "y", "1", "on", "false", "no", "n", "0", "off"].contains(value.lowercased())
            default: false
            }
        }
        guard !unreadable.isEmpty else { return nil }
        return "\(unreadable.count) of \(all.count) values cannot be read as \(type.label.lowercased()) and will be left empty, for example “\(unreadable[0])”."
    }

    private func shortDestinationLabel(at index: Int) -> String {
        switch destination(at: index) {
        case .ignore: "Don't import"
        case .standard(.title) where titleColumnIndices.count > 1: "Title part \(titlePartNumber(at: index) ?? 1)"
        case .standard(let field): field.label
        case .existingMetadata(let id): metadataFields.first { $0.id == id }?.name ?? "Missing field"
        case .newMetadata: "New: \(resolvedNewFieldName(at: index))"
        }
    }

    /// The preview names both roles of a column, so a color that also feeds the
    /// title reads as "Color + title 3" rather than hiding one of its jobs.
    private func previewDestinationLabel(at index: Int) -> String {
        let base = shortDestinationLabel(at: index)
        guard let part = titlePartNumber(at: index), destination(at: index) != .standard(.title) else { return base }
        return "\(base) + title \(part)"
    }

    private func destinationSymbol(at index: Int) -> String {
        switch destination(at: index) {
        case .ignore: "minus.circle"
        case .standard(let field): symbol(for: field)
        case .existingMetadata(let id): metadataFields.first { $0.id == id }?.type.symbol ?? "questionmark.circle"
        case .newMetadata(let type): type.symbol
        }
    }

    private func symbol(for field: HTMLImportField) -> String {
        switch field {
        case .title: "textformat.characters"
        case .brand: "building.2"
        case .variant: "square.on.square"
        case .description: "text.alignleft"
        case .state: "flag"
        case .quantity: "number"
        case .barcode: "barcode"
        case .tags: "tag"
        case .ignore: "minus.circle"
        }
    }

    // MARK: - Bindings and mutations

    private func newFieldNameBinding(at index: Int, header: String) -> Binding<String> {
        Binding(
            get: { newFieldNames[index] ?? header },
            set: { newFieldNames[index] = $0 }
        )
    }

    private func newFieldTypeBinding(at index: Int) -> Binding<MetadataFieldType> {
        Binding(
            get: {
                if case .newMetadata(let type) = destination(at: index) { return type }
                return .text
            },
            set: { setMapping(.newMetadata($0), at: index) }
        )
    }

    private func setMapping(_ destination: ImportColumnDestination, at index: Int) {
        guard mapping.indices.contains(index) else { return }
        // The same item field or existing custom field can only be filled once,
        // so claiming it elsewhere releases the column that held it before.
        switch destination {
        case .standard(let field) where field != .title:
            for other in mapping.indices where other != index && mapping[other] == .standard(field) { mapping[other] = .ignore }
        case .standard:
            break
        case .existingMetadata(let fieldID):
            for other in mapping.indices where other != index && mapping[other] == .existingMetadata(fieldID) { mapping[other] = .ignore }
        default:
            break
        }
        if destination == .standard(.title) {
            titleColumns.insert(index)
        } else if mapping[index] == .standard(.title) {
            // The column was only there for the title; moving it elsewhere
            // takes it out of the title unless the toggle is turned back on.
            titleColumns.remove(index)
        }
        mapping[index] = destination
    }

    private func rebuildTable(resuggestMapping: Bool) {
        let rows = importer.rows(in: file.text, delimiter: delimiter)
        table = importer.makeTable(rows: rows, firstRowIsHeader: firstRowIsHeader)
        if resuggestMapping || mapping.count != table.headers.count {
            mapping = importer.suggestMapping(for: table, existingMetadataFields: metadataFields, ensuresTitleColumn: true)
            titleColumns = Set(mapping.indices.filter { mapping[$0] == .standard(.title) })
            newFieldNames = [:]
            conditionalRules = conditionalRules.filter { rule in
                table.headers.contains { $0.localizedCaseInsensitiveCompare(rule.sourceColumn) == .orderedSame }
            }
        }
    }

    private func prepareReview() {
        preparation = importer.prepareImport(
            from: table,
            mapping: mapping,
            existingMetadataFields: metadataFields,
            conditionalRules: conditionalRules,
            validStatusIDs: Set(store.statuses.map(\.id)),
            newFieldNames: newFieldNames,
            titleColumns: titleColumnIndices
        )
    }
}

/// A titled panel. The import screen is a scroll view rather than a form so the
/// column rows can lay out side by side, so it brings its own grouping.
private struct ImportCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}

private struct ConditionalRuleRow: View {
    let headers: [String]
    let statuses: [CollectionStatus]
    let metadataFields: [MetadataFieldDefinition]
    @Binding var rule: ConditionalMappingRule
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("If")
                    .foregroundStyle(.secondary)
                Picker("Column", selection: $rule.sourceColumn) {
                    if !headers.contains(where: { $0.localizedCaseInsensitiveCompare(rule.sourceColumn) == .orderedSame }) {
                        Text("Missing: \(rule.sourceColumn)").tag(rule.sourceColumn)
                    }
                    ForEach(headers, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("is")
                    .foregroundStyle(.secondary)
                TextField("value", text: $rule.equalsValue)
                    .textFieldStyle(.roundedBorder)
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            HStack {
                Text("then")
                    .foregroundStyle(.secondary)
                Picker("Action", selection: actionKind) {
                    Text("set status").tag(0)
                    if !metadataFields.isEmpty { Text("set custom field").tag(1) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                switch rule.action {
                case .status:
                    Picker("Status", selection: statusID) {
                        if case .status(let currentID) = rule.action, !statuses.contains(where: { $0.id == currentID }) {
                            Text("Unavailable status").tag(currentID)
                        }
                        ForEach(statuses) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                case .metadata:
                    Picker("Field", selection: metadataFieldID) {
                        if case .metadata(let currentID, _) = rule.action, !metadataFields.contains(where: { $0.id == currentID }) {
                            Text("Unavailable field").tag(currentID)
                        }
                        ForEach(metadataFields) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    TextField("value", text: metadataValue)
                        .textFieldStyle(.roundedBorder)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color.platformGroupedBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var actionKind: Binding<Int> {
        Binding(get: {
            if case .metadata = rule.action { return 1 }
            return 0
        }, set: { kind in
            if kind == 0 {
                if let status = statuses.first { rule.action = .status(status.id) }
            } else if let field = metadataFields.first {
                rule.action = .metadata(fieldID: field.id, value: "")
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
            if case .metadata(_, let existing) = rule.action { value = existing } else { value = "" }
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
}
