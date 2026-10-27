import Foundation

nonisolated struct CSVSourceAnalysis: Sendable {
    let table: CSVImportTable
    let suggestedMapping: [ImportColumnDestination]
}

nonisolated struct CSVColumnAnalysis: Sendable {
    let examples: [String]
    let suggestedType: MetadataFieldType?
    let populatedCount: Int
    let unreadableCount: Int
    let firstUnreadable: String?
}

nonisolated struct CSVMappingAnalysis: Sendable {
    let columns: [Int: CSVColumnAnalysis]
    let importableRowCount: Int
    let duplicateTitleCount: Int
    let exampleTitle: String?
}

/// Immutable analysis for the mapping screen. Call from a cancellable worker;
/// the UI formats the returned facts without rescanning source rows in body.
nonisolated enum CSVImportAnalysis {
    static func source(text: String, delimiter: CSVDelimiter, firstRowIsHeader: Bool,
                       metadataFields: [MetadataFieldDefinition]) throws -> CSVSourceAnalysis {
        try Task.checkCancellation()
        let importer = CollectionImporter()
        let rows = importer.rows(in: text, delimiter: delimiter)
        try Task.checkCancellation()
        let table = importer.makeTable(rows: rows, firstRowIsHeader: firstRowIsHeader)
        try Task.checkCancellation()
        let mapping = importer.suggestMapping(for: table, existingMetadataFields: metadataFields, ensuresTitleColumn: true)
        try Task.checkCancellation()
        return CSVSourceAnalysis(table: table, suggestedMapping: mapping)
    }

    static func mapping(table: CSVImportTable, mapping: [ImportColumnDestination], titleColumns: [Int],
                        existingItems: [CollectionItem], collectionID: UUID) throws -> CSVMappingAnalysis {
        try Task.checkCancellation()
        let importer = CollectionImporter()
        var columns: [Int: CSVColumnAnalysis] = [:]
        for index in table.headers.indices {
            try Task.checkCancellation()
            var singleColumnRows: [[String]] = []
            singleColumnRows.reserveCapacity(table.rows.count)
            var examples: [String] = [], populated = 0, unreadable = 0
            var firstUnreadable: String?
            let selectedType: MetadataFieldType?
            if mapping.indices.contains(index), case .newMetadata(let type) = mapping[index], type == .number || type == .date || type == .boolean { selectedType = type }
            else { selectedType = nil }
            for (rowNumber, row) in table.rows.enumerated() {
                if rowNumber.isMultiple(of: 256) { try Task.checkCancellation() }
                let raw = row.indices.contains(index) ? row[index] : ""
                singleColumnRows.append([raw])
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                populated += 1
                if examples.count < 3 { examples.append(value) }
                guard let selectedType else { continue }
                if !canRead(value, as: selectedType, header: table.headers[index]) {
                    unreadable += 1
                    if firstUnreadable == nil { firstUnreadable = value }
                }
            }
            try Task.checkCancellation()
            // Use the same one-column inference as the mapping editor, including
            // standard-header detection and its existing date/boolean precedence.
            let suggested = importer.suggestMapping(for: CSVImportTable(headers: [table.headers[index]], rows: singleColumnRows), existingMetadataFields: [])
            try Task.checkCancellation()
            let suggestedType: MetadataFieldType?
            if case .newMetadata(let type) = suggested.first { suggestedType = type }
            else { suggestedType = nil }
            columns[index] = CSVColumnAnalysis(examples: examples, suggestedType: suggestedType, populatedCount: populated,
                                               unreadableCount: unreadable, firstUnreadable: firstUnreadable)
        }

        let titles = Set(titleColumns).filter { table.headers.indices.contains($0) }.sorted()
        guard !titles.isEmpty else {
            return CSVMappingAnalysis(columns: columns, importableRowCount: 0, duplicateTitleCount: 0, exampleTitle: nil)
        }
        let brand = mapping.firstIndex(of: .standard(.brand))
        let variant = mapping.firstIndex(of: .standard(.variant))
        var seen = Set<String>()
        for (index, item) in existingItems.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if item.collectionID == collectionID { seen.insert("\(item.title.lowercased())|\(item.brand.lowercased())|\(item.variant.lowercased())") }
        }
        var importable = 0, duplicates = 0
        var exampleTitle: String?
        for (index, row) in table.rows.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let title = titles.compactMap { column -> String? in
                guard row.indices.contains(column) else { return nil }
                let value = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }.joined(separator: " ")
            guard !title.isEmpty else { continue }
            importable += 1
            if exampleTitle == nil { exampleTitle = title }
            let key = "\(title.lowercased())|\(part(brand, row))|\(part(variant, row))"
            if !seen.insert(key).inserted { duplicates += 1 }
        }
        try Task.checkCancellation()
        return CSVMappingAnalysis(columns: columns, importableRowCount: importable, duplicateTitleCount: duplicates, exampleTitle: exampleTitle)
    }

    private static func part(_ index: Int?, _ row: [String]) -> String {
        guard let index, row.indices.contains(index) else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func canRead(_ value: String, as type: MetadataFieldType, header: String) -> Bool {
        switch type {
        case .number: Double(value.replacingOccurrences(of: ",", with: ".")) != nil
        case .date: MetadataDateParser.parse(value, hint: header) != nil
        case .boolean: ["true", "yes", "y", "1", "on", "false", "no", "n", "0", "off"].contains(value.lowercased())
        default: true
        }
    }
}
