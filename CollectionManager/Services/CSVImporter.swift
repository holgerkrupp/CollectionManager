import Foundation

struct ImportDraft: Identifiable, Sendable {
    let id = UUID()
    var title: String
    var brand: String
    var variant: String
    var description: String
    var state: ItemState
    var quantity: Int
    var tags: [String]
    var barcode: Barcode?
    var sourceIdentifier: String? = nil
    var metadata: [String: MetadataValue] = [:]
}

struct CSVImportTable: Identifiable, Sendable {
    let id = UUID()
    var headers: [String]
    var rows: [[String]]
}

/// The separators a spreadsheet export realistically uses. Detection picks one
/// automatically, but the import screen lets people override it because a file
/// full of semicolons inside quoted text can fool any heuristic.
enum CSVDelimiter: String, CaseIterable, Identifiable, Codable, Sendable {
    case comma
    case semicolon
    case tab
    case pipe

    var id: String { rawValue }

    var character: Character {
        switch self {
        case .comma: ","
        case .semicolon: ";"
        case .tab: "\t"
        case .pipe: "|"
        }
    }

    var label: String {
        switch self {
        case .comma: "Comma  ,"
        case .semicolon: "Semicolon  ;"
        case .tab: "Tab"
        case .pipe: "Pipe  |"
        }
    }
}

/// A CSV file that has been read but not yet interpreted. Keeping the raw text
/// around lets the import screen re-parse instantly when the delimiter or the
/// header setting changes, without touching the file again.
struct CSVParsedFile: Identifiable, Sendable {
    let id = UUID()
    var fileName: String
    var text: String
    var detectedDelimiter: CSVDelimiter
    var suggestsHeaderRow: Bool
}

enum ImportColumnDestination: Hashable, Codable, Sendable {
    case ignore
    case standard(HTMLImportField)
    case existingMetadata(UUID)
    case newMetadata(MetadataFieldType)
}

enum ConditionalMappingAction: Hashable, Codable, Sendable {
    case status(String)
    case metadata(fieldID: UUID, value: String)
}

struct ConditionalMappingRule: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var sourceColumn: String
    var equalsValue: String
    var action: ConditionalMappingAction

    func matches(headers: [String], row: [String]) -> Bool {
        guard let index = headers.firstIndex(where: { $0.localizedCaseInsensitiveCompare(sourceColumn) == .orderedSame }), row.indices.contains(index) else { return false }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(equalsValue.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}

struct ImportPreparation: Identifiable, Sendable {
    let id = UUID()
    let drafts: [ImportDraft]
    let newMetadataFields: [MetadataFieldDefinition]
    let metadataFields: [MetadataFieldDefinition]
}

struct MetadataMappingPreparation: Sendable {
    let metadata: [String: MetadataValue]
    let newMetadataFields: [MetadataFieldDefinition]
}

struct CollectionImporter {
    nonisolated init() {}

    nonisolated func parseTable(_ data: Data) throws -> CSVImportTable {
        guard var text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        if text.first == "\u{feff}" { text.removeFirst() }
        let delimiter = detectedDelimiter(in: text)
        let rows = parseRows(text, delimiter: delimiter).filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard let rawHeader = rows.first else { return CSVImportTable(headers: [], rows: []) }

        var headerCounts: [String: Int] = [:]
        let headers = rawHeader.enumerated().map { index, rawValue in
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? "Column \(index + 1)" : trimmed
            headerCounts[base, default: 0] += 1
            let count = headerCounts[base, default: 1]
            return count == 1 ? base : "\(base) \(count)"
        }
        return CSVImportTable(headers: headers, rows: Array(rows.dropFirst()))
    }

    /// Reads the file without deciding yet how it should be interpreted. The
    /// import screen makes the header and delimiter choices explicit instead.
    nonisolated func parseFile(_ data: Data, fileName: String) throws -> CSVParsedFile {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if text.first == "\u{feff}" { text.removeFirst() }
        let delimiter = CSVDelimiter.allCases.first { $0.character == detectedDelimiter(in: text) } ?? .comma
        let rows = rows(in: text, delimiter: delimiter)
        return CSVParsedFile(fileName: fileName, text: text, detectedDelimiter: delimiter, suggestsHeaderRow: looksLikeHeaderRow(rows))
    }

    /// Splits the raw text into rows, dropping only the rows that are entirely
    /// empty so the row numbers people see match the file as closely as possible.
    nonisolated func rows(in text: String, delimiter: CSVDelimiter) -> [[String]] {
        parseRows(text, delimiter: delimiter.character).filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    /// Builds the mappable table. Without a header row the columns are named
    /// positionally so every column still has something to point at.
    nonisolated func makeTable(rows: [[String]], firstRowIsHeader: Bool) -> CSVImportTable {
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return CSVImportTable(headers: [], rows: []) }

        let headers: [String]
        let bodyRows: [[String]]
        if firstRowIsHeader, let rawHeader = rows.first {
            var headerCounts: [String: Int] = [:]
            headers = (0..<columnCount).map { index in
                let trimmed = index < rawHeader.count ? rawHeader[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let base = trimmed.isEmpty ? "Column \(index + 1)" : trimmed
                headerCounts[base, default: 0] += 1
                let count = headerCounts[base, default: 1]
                return count == 1 ? base : "\(base) \(count)"
            }
            bodyRows = Array(rows.dropFirst())
        } else {
            headers = (0..<columnCount).map { "Column \($0 + 1)" }
            bodyRows = rows
        }

        let padded = bodyRows.map { row in
            row.count == columnCount ? row : row + Array(repeating: "", count: max(0, columnCount - row.count))
        }
        return CSVImportTable(headers: headers, rows: padded)
    }

    /// A header row usually consists of short, filled-in labels that do not look
    /// like the data underneath it, so numbers, dates and booleans argue against it.
    nonisolated func looksLikeHeaderRow(_ rows: [[String]]) -> Bool {
        guard let first = rows.first, rows.count > 1 else { return false }
        let values = first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !values.isEmpty else { return false }
        return values.allSatisfy { value in
            parseNumber(value) == nil && parseBoolean(value) == nil && MetadataDateParser.parse(value, hint: "") == nil
        }
    }

    // Kept for callers that only need automatic built-in mapping.
    nonisolated func parseCSV(_ data: Data) throws -> [ImportDraft] {
        let table = try parseTable(data)
        let mapping = suggestMapping(for: table, existingMetadataFields: [])
        return prepareImport(from: table, mapping: mapping, existingMetadataFields: []).drafts
    }

    nonisolated func suggestMapping(for table: CSVImportTable, existingMetadataFields: [MetadataFieldDefinition], ensuresTitleColumn: Bool = false) -> [ImportColumnDestination] {
        var mapping: [ImportColumnDestination] = table.headers.enumerated().map { index, header in
            if let standard = suggestedStandardField(for: header) { return .standard(standard) }
            if let existing = existingMetadataFields.first(where: { normalizedName($0.name) == normalizedName(header) }) {
                return .existingMetadata(existing.id)
            }
            let values = table.rows.compactMap { index < $0.count ? $0[index] : nil }
            return ImportColumnDestination.newMetadata(inferredType(header: header, values: values))
        }
        // An import without a title cannot produce items at all, so when no
        // column names itself the title, the first mostly-filled text column is
        // proposed. It stays a suggestion the user can move elsewhere.
        if ensuresTitleColumn, !mapping.contains(.standard(.title)) {
            let candidate = table.headers.indices.first { index in
                let values = table.rows.compactMap { index < $0.count ? $0[index].trimmingCharacters(in: .whitespacesAndNewlines) : nil }
                let populated = values.filter { !$0.isEmpty }
                guard !populated.isEmpty, populated.count * 2 >= values.count else { return false }
                return populated.contains { parseNumber($0) == nil && parseBoolean($0) == nil }
            }
            if let candidate { mapping[candidate] = .standard(.title) }
        }
        return mapping
    }

    /// - Parameter titleColumns: Columns whose values are joined into the title,
    ///   in the given order. A column listed here still lands in whatever field
    ///   `mapping` assigns it, so a color can be part of the name and remain its
    ///   own field. When empty, the columns mapped to `.title` are used.
    nonisolated func prepareImport(from table: CSVImportTable, mapping: [ImportColumnDestination], existingMetadataFields: [MetadataFieldDefinition], sourceIdentifierColumn: Int? = nil, conditionalRules: [ConditionalMappingRule] = [], validStatusIDs: Set<String>? = nil, newFieldNames: [Int: String] = [:], titleColumns: [Int] = []) -> ImportPreparation {
        var usedNames = Set(existingMetadataFields.map { normalizedName($0.name) })
        var newFieldsByColumn: [Int: MetadataFieldDefinition] = [:]
        for (index, destination) in mapping.enumerated() {
            guard case .newMetadata(let type) = destination, index < table.headers.count else { continue }
            let customName = newFieldNames[index]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = customName.flatMap { $0.isEmpty ? nil : $0 } ?? displayName(for: table.headers[index])
            var name = baseName
            var suffix = 2
            while usedNames.contains(normalizedName(name)) {
                name = "\(baseName) \(suffix)"
                suffix += 1
            }
            usedNames.insert(normalizedName(name))
            newFieldsByColumn[index] = MetadataFieldDefinition(name: name, type: type)
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existingMetadataFields.map { ($0.id, $0) })
        let drafts = table.rows.compactMap { row -> ImportDraft? in
            func rawValue(at index: Int) -> String {
                guard index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Several columns may feed the same field — a title assembled from
            // model, generation and color is what makes rows of a product matrix
            // distinguishable — so every column mapped to a field is joined.
            func value(_ field: HTMLImportField) -> String {
                let parts = mapping.indices.filter { mapping[$0] == .standard(field) }.map(rawValue(at:)).filter { !$0.isEmpty }
                let separator = field == .description ? " · " : " "
                return parts.joined(separator: separator)
            }

            let titleIndices = titleColumns.isEmpty ? mapping.indices.filter { mapping[$0] == .standard(.title) } : titleColumns
            let title = titleIndices.map(rawValue(at:)).filter { !$0.isEmpty }.joined(separator: " ")
            guard !title.isEmpty else { return nil }
            let rawState = value(.state).lowercased()
            let state = ItemState(rawValue: rawState.isEmpty ? "wanted" : rawState.contains("storage") || rawState.contains("lager") ? "stored" : rawState.contains("consum") || rawState.contains("getrun") ? "consumed" : rawState)
            var metadata: [String: MetadataValue] = [:]
            for (index, destination) in mapping.enumerated() {
                let field: MetadataFieldDefinition?
                switch destination {
                case .existingMetadata(let id): field = existingByID[id]
                case .newMetadata: field = newFieldsByColumn[index]
                default: field = nil
                }
                let hint = index < table.headers.count ? table.headers[index] : field?.name ?? ""
                guard let field, let parsed = metadataValue(rawValue(at: index), as: field.type, hint: hint) else { continue }
                metadata[field.storageKey] = parsed
            }

            var draft = ImportDraft(
                title: title,
                brand: value(.brand),
                variant: value(.variant),
                description: value(.description),
                state: state,
                quantity: max(Int(value(.quantity)) ?? 1, 1),
                tags: splitTags(value(.tags)),
                barcode: Barcode(rawValue: value(.barcode)),
                sourceIdentifier: sourceIdentifierColumn.map(rawValue(at:)),
                metadata: metadata
            )
            for rule in conditionalRules where rule.matches(headers: table.headers, row: row) {
                switch rule.action {
                case .status(let statusID):
                    guard validStatusIDs?.contains(statusID) != false else { continue }
                    draft.state = ItemState(rawValue: statusID)
                case .metadata(let fieldID, let value):
                    guard let field = existingByID[fieldID], let parsed = metadataValue(value.trimmingCharacters(in: .whitespacesAndNewlines), as: field.type, hint: field.name) else { continue }
                    draft.metadata[field.storageKey] = parsed
                }
            }
            return draft
        }
        let newFields = newFieldsByColumn.keys.sorted().compactMap { newFieldsByColumn[$0] }
        return ImportPreparation(drafts: drafts, newMetadataFields: newFields, metadataFields: existingMetadataFields + newFields)
    }

    nonisolated func suggestMetadataMapping(headers: [String], existingMetadataFields: [MetadataFieldDefinition]) -> [ImportColumnDestination] {
        headers.map { header in
            if let existing = existingMetadataFields.first(where: { normalizedName($0.name) == normalizedName(header) }) {
                return .existingMetadata(existing.id)
            }
            return .ignore
        }
    }

    nonisolated func prepareMetadataMapping(headers: [String], values: [String], mapping: [ImportColumnDestination], existingMetadataFields: [MetadataFieldDefinition]) -> MetadataMappingPreparation {
        var usedNames = Set(existingMetadataFields.map { normalizedName($0.name) })
        var newFieldsByIndex: [Int: MetadataFieldDefinition] = [:]
        for (index, destination) in mapping.enumerated() {
            guard case .newMetadata(let type) = destination, headers.indices.contains(index) else { continue }
            let baseName = displayName(for: headers[index])
            var name = baseName
            var suffix = 2
            while usedNames.contains(normalizedName(name)) { name = "\(baseName) \(suffix)"; suffix += 1 }
            usedNames.insert(normalizedName(name))
            newFieldsByIndex[index] = MetadataFieldDefinition(name: name, type: type)
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existingMetadataFields.map { ($0.id, $0) })
        var metadata: [String: MetadataValue] = [:]
        for (index, destination) in mapping.enumerated() where values.indices.contains(index) {
            let field: MetadataFieldDefinition?
            switch destination {
            case .existingMetadata(let id): field = existingByID[id]
            case .newMetadata: field = newFieldsByIndex[index]
            default: field = nil
            }
            guard let field, let parsed = metadataValue(values[index].trimmingCharacters(in: .whitespacesAndNewlines), as: field.type, hint: headers.indices.contains(index) ? headers[index] : field.name) else { continue }
            metadata[field.storageKey] = parsed
        }
        return MetadataMappingPreparation(metadata: metadata, newMetadataFields: newFieldsByIndex.keys.sorted().compactMap { newFieldsByIndex[$0] })
    }

    nonisolated private func suggestedStandardField(for header: String) -> HTMLImportField? {
        let value = normalizedName(header)
        if ["title", "name", "product", "productname", "model", "text"].contains(value) || value.contains("drink") || value.contains("getrank") { return .title }
        if value.contains("brand") || value.contains("manufacturer") || value.contains("marke") { return .brand }
        if value.contains("variant") || value.contains("flavour") || value.contains("flavor") || value.contains("geschmack") { return .variant }
        if value.contains("description") || value.contains("notes") || value == "note" || value.contains("url") || value == "href" { return .description }
        if value.contains("state") || value.contains("status") || value.contains("zustand") { return .state }
        if value.contains("quantity") || value.contains("count") || value.contains("anzahl") { return .quantity }
        if value.contains("barcode") || value.contains("ean") || value.contains("upc") { return .barcode }
        if value.contains("tag") || value.contains("label") || value.contains("kategorie") { return .tags }
        return nil
    }

    nonisolated private func inferredType(header: String, values: [String]) -> MetadataFieldType {
        let populated = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !populated.isEmpty else { return .text }
        let normalizedHeader = normalizedName(header)
        if normalizedHeader.contains("color") || normalizedHeader.contains("colour") || normalizedHeader.contains("farbe") { return .color }
        let hasDateHint = normalizedHeader.contains("date") || normalizedHeader.contains("datum") || normalizedHeader.contains("week") || normalizedHeader.contains("woche") || normalizedHeader.contains("year") || normalizedHeader.contains("jahr") || normalizedHeader == "kw" || normalizedHeader == "cw"
        if hasDateHint, populated.allSatisfy({ MetadataDateParser.parse($0, hint: header) != nil }) { return .date }
        if populated.allSatisfy({ parseBoolean($0) != nil }) { return .boolean }
        if populated.allSatisfy({ MetadataDateParser.parse($0, hint: header) != nil }) { return .date }
        if populated.allSatisfy({ parseNumber($0) != nil }) { return .number }
        return .text
    }

    nonisolated private func metadataValue(_ rawValue: String, as type: MetadataFieldType, hint: String) -> MetadataValue? {
        guard !rawValue.isEmpty else { return nil }
        switch type {
        case .text: return .string(rawValue)
        case .number: return parseNumber(rawValue).map(MetadataValue.decimal)
        case .date: return MetadataDateParser.parse(rawValue, hint: hint).map(MetadataValue.date)
        case .boolean: return parseBoolean(rawValue).map(MetadataValue.boolean)
        case .color: return .string(rawValue)
        }
    }

    nonisolated private func splitTags(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.split { ",|;/".contains($0) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty && seen.insert($0.lowercased()).inserted
        }
    }

    nonisolated private func parseNumber(_ value: String) -> Double? {
        let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(compact) { return number }
        if compact.contains(","), !compact.contains(".") { return Double(compact.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    nonisolated private func parseBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "y", "1", "on": return true
        case "false", "no", "n", "0", "off": return false
        default: return nil
        }
    }

    nonisolated private func displayName(for header: String) -> String {
        let words = header.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"[._/\-]+"#, with: " ", options: .regularExpression)
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Imported field" : trimmed.capitalized
    }

    nonisolated private func normalizedName(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }

    nonisolated private func detectedDelimiter(in text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t"]
        var counts = Dictionary(uniqueKeysWithValues: candidates.map { ($0, 0) })
        var isQuoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" { isQuoted.toggle() }
            if !isQuoted, character.isNewline { break }
            if !isQuoted, counts[character] != nil { counts[character, default: 0] += 1 }
            index = text.index(after: index)
        }
        return candidates.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? ","
    }

    nonisolated private func parseRows(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = text.startIndex

        func finishField() {
            row.append(field)
            field.removeAll(keepingCapacity: true)
        }
        func finishRow() {
            finishField()
            rows.append(row)
            row.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if isQuoted && next < text.endIndex && text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    isQuoted.toggle()
                }
            } else if character == delimiter && !isQuoted {
                finishField()
            } else if character.isNewline && !isQuoted {
                // Swift stores a CRLF pair as one Character, so testing for
                // "\n" alone would miss every line break in a Windows or
                // spreadsheet export and collapse the file into a single row.
                finishRow()
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty { finishRow() }
        return rows
    }
}
