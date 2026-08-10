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

enum ImportColumnDestination: Hashable, Codable, Sendable {
    case ignore
    case standard(HTMLImportField)
    case existingMetadata(UUID)
    case newMetadata(MetadataFieldType)
}

struct ImportPreparation: Identifiable, Sendable {
    let id = UUID()
    let drafts: [ImportDraft]
    let newMetadataFields: [MetadataFieldDefinition]
    let metadataFields: [MetadataFieldDefinition]
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

    // Kept for callers that only need automatic built-in mapping.
    nonisolated func parseCSV(_ data: Data) throws -> [ImportDraft] {
        let table = try parseTable(data)
        let mapping = suggestMapping(for: table, existingMetadataFields: [])
        return prepareImport(from: table, mapping: mapping, existingMetadataFields: []).drafts
    }

    nonisolated func suggestMapping(for table: CSVImportTable, existingMetadataFields: [MetadataFieldDefinition]) -> [ImportColumnDestination] {
        table.headers.enumerated().map { index, header in
            if let standard = suggestedStandardField(for: header) { return .standard(standard) }
            if let existing = existingMetadataFields.first(where: { normalizedName($0.name) == normalizedName(header) }) {
                return .existingMetadata(existing.id)
            }
            let values = table.rows.compactMap { index < $0.count ? $0[index] : nil }
            return .newMetadata(inferredType(header: header, values: values))
        }
    }

    nonisolated func prepareImport(from table: CSVImportTable, mapping: [ImportColumnDestination], existingMetadataFields: [MetadataFieldDefinition], sourceIdentifierColumn: Int? = nil) -> ImportPreparation {
        var usedNames = Set(existingMetadataFields.map { normalizedName($0.name) })
        var newFieldsByColumn: [Int: MetadataFieldDefinition] = [:]
        for (index, destination) in mapping.enumerated() {
            guard case .newMetadata(let type) = destination, index < table.headers.count else { continue }
            let baseName = displayName(for: table.headers[index])
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
            func value(_ field: HTMLImportField) -> String {
                guard let index = mapping.firstIndex(of: .standard(field)) else { return "" }
                return rawValue(at: index)
            }

            let title = value(.title)
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

            return ImportDraft(
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
        }
        let newFields = newFieldsByColumn.keys.sorted().compactMap { newFieldsByColumn[$0] }
        return ImportPreparation(drafts: drafts, newMetadataFields: newFields, metadataFields: existingMetadataFields + newFields)
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
        let words = header.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
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
            if !isQuoted, character == "\n" || character == "\r" { break }
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
            } else if (character == "\n" || character == "\r") && !isQuoted {
                finishRow()
                if character == "\r" {
                    let next = text.index(after: index)
                    if next < text.endIndex && text[next] == "\n" { index = next }
                }
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty { finishRow() }
        return rows
    }
}
