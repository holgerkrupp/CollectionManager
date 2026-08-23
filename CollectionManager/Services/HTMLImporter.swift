import Foundation

enum HTMLImportField: String, CaseIterable, Codable, Identifiable, Sendable {
    case title, brand, variant, description, state, quantity, barcode, tags, ignore
    var id: String { rawValue }
    var label: String { switch self { case .title: "Title"; case .brand: "Brand"; case .variant: "Variant"; case .description: "Description"; case .state: "State"; case .quantity: "Quantity"; case .barcode: "Barcode"; case .tags: "Tags"; case .ignore: "Ignore" } }
}

struct HTMLImportTable: Identifiable, Sendable {
    let id = UUID(); var name: String; var headers: [String]; var rows: [[String]]
}

struct HTMLImporter {
    func load(url: URL) async throws -> [HTMLImportTable] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw URLError(.badServerResponse) }
        return try parse(data: data, name: url.lastPathComponent.isEmpty ? url.host ?? "Web page" : url.lastPathComponent)
    }

    func parse(data: Data, name: String = "HTML file") throws -> [HTMLImportTable] {
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw CocoaError(.fileReadCorruptFile) }
        // List pages usually contain more useful object metadata than a table or
        // the visible text of a link, so give them priority when present.
        var tables = parseLists(html)
        if tables.isEmpty { tables = parseTables(html) }
        if tables.isEmpty { tables = parseLinkedObjects(html) }
        guard !tables.isEmpty else { throw HTMLImportError.noObjects }
        return tables
    }

    func suggestMapping(for table: HTMLImportTable, existingMetadataFields: [MetadataFieldDefinition] = []) -> [ImportColumnDestination] {
        CollectionImporter().suggestMapping(
            for: CSVImportTable(headers: table.headers, rows: table.rows),
            existingMetadataFields: existingMetadataFields
        )
    }

    func prepareImport(from table: HTMLImportTable, mapping: [ImportColumnDestination], existingMetadataFields: [MetadataFieldDefinition], conditionalRules: [ConditionalMappingRule] = [], validStatusIDs: Set<String>? = nil) -> ImportPreparation {
        let sourceIndex = table.headers.firstIndex {
            $0.localizedCaseInsensitiveContains("url") ||
            $0.localizedCaseInsensitiveContains("source") ||
            $0.localizedCaseInsensitiveCompare("href") == .orderedSame
        }
        return CollectionImporter().prepareImport(
            from: CSVImportTable(headers: table.headers, rows: table.rows),
            mapping: mapping,
            existingMetadataFields: existingMetadataFields,
            sourceIdentifierColumn: sourceIndex,
            conditionalRules: conditionalRules,
            validStatusIDs: validStatusIDs
        )
    }

    private func parseTables(_ html: String) -> [HTMLImportTable] { let tablePattern = #"(?is)<table\b[^>]*>(.*?)</table>"#; let tableMatches = matches(tablePattern, in: html); return tableMatches.enumerated().compactMap { index, tableHTML in let rowMatches = matches(#"(?is)<tr\b[^>]*>(.*?)</tr>"#, in: tableHTML); let rows = rowMatches.map { matches(#"(?is)<t[hd]\b[^>]*>(.*?)</t[hd]>"#, in: $0).map(clean) }.filter { $0.count > 0 }; guard let headers = rows.first, rows.count > 1 else { return nil }; return HTMLImportTable(name: "Table \(index + 1)", headers: headers, rows: rows.dropFirst().map { Array($0) }) } }

    private func parseLists(_ html: String) -> [HTMLImportTable] {
        let listMatches = matches(#"(?is)<(?:ul|ol)\b[^>]*>(.*?)</(?:ul|ol)>"#, in: html)
        let tables: [HTMLImportTable] = listMatches.enumerated().compactMap { index, listHTML -> HTMLImportTable? in
            let itemMatches = captureMatches(#"(?is)<li\b([^>]*)>(.*?)</li\s*>"#, in: listHTML)
            let rows = itemMatches.map { item in listRow(attributes: item[0], body: item[1]) }
            let headers = rows.reduce(into: [String]()) { result, row in
                for key in row.keys where !result.contains(key) { result.append(key) }
            }
            guard rows.count > 1, !headers.isEmpty else { return nil }
            return HTMLImportTable(name: "List \(index + 1)", headers: headers, rows: rows.map { row in headers.map { rowValue($0, in: row) } })
        }
        // Navigation lists are common on web pages. Prefer the list with the
        // most repeated, mappable data while still exposing the other lists.
        return tables.sorted { left, right in
            left.rows.count * left.headers.count > right.rows.count * right.headers.count
        }
    }

    private func listRow(attributes: String, body: String) -> [String: String] {
        var values: [String: String] = [:]
        addAttributes(attributes, to: &values)

        let elementMatches = captureMatches(#"(?is)<([a-z][a-z0-9:-]*)\b([^>]*)>(.*?)</\1\s*>"#, in: body)
        for element in elementMatches {
            let tag = element[0].lowercased()
            let elementAttributes = element[1]
            let text = clean(element[2])
            addAttributes(elementAttributes, to: &values, text: text, tag: tag)
            if tag == "a", !text.isEmpty { addValue(text, for: "Title", in: &values) }
        }

        // The general element expression above can consume a parent element
        // before a nested element. This second pass deliberately handles leaf
        // elements so their own class/id/data-* property receives its text.
        for element in captureMatches(#"(?is)<([a-z][a-z0-9:-]*)\b([^>]*)>([^<]*)</\1\s*>"#, in: body) {
            addAttributes(element[1], to: &values, text: clean(element[2]), tag: element[0].lowercased())
        }

        // Also inspect self-closing and otherwise irregular descendants so no
        // attribute is lost just because the element has no text node.
        for element in captureMatches(#"(?is)<([a-z][a-z0-9:-]*)\b([^>]*)>"#, in: body) {
            addAttributes(element[1], to: &values, tag: element[0].lowercased())
        }
        if values.isEmpty || !values.values.contains(where: { !$0.isEmpty }) { addValue(clean(body), for: "Text", in: &values) }
        return values
    }

    private func addAttributes(_ source: String, to values: inout [String: String], text: String = "", tag: String = "") {
        for attribute in captureMatches(#"(?is)([a-z_:][a-z0-9_:.\-]*)\s*=\s*([\"'])(.*?)\2"#, in: source) {
            let name = attribute[0].lowercased()
            let value = clean(attribute[2])
            addValue(value, for: name, in: &values)
            if name.hasPrefix("data-") { addValue(value, for: String(name.dropFirst(5)), in: &values) }
            if name == "class" { for token in value.split(whereSeparator: { $0 == " " || $0 == "." }) { if !text.isEmpty { addValue(text, for: String(token), in: &values) } } }
            if name == "id" || name == "name" || name == "itemprop" || name == "aria-label" { if !text.isEmpty { addValue(text, for: value, in: &values) } }
            if name == "href" { addValue(value, for: "Source URL", in: &values) }
        }
        if !text.isEmpty, tag == "img" { addValue(text, for: "Image", in: &values) }
    }

    private func addValue(_ value: String, for key: String, in values: inout [String: String]) { guard !value.isEmpty else { return }; if let existing = values[key], !existing.isEmpty, existing != value { values[key] = "\(existing); \(value)" } else { values[key] = value } }
    private func rowValue(_ key: String, in row: [String: String]) -> String { row[key] ?? "" }
    private func parseLinkedObjects(_ html: String) -> [HTMLImportTable] { let pattern = #"(?is)<a\b[^>]*href\s*=\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#; guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }; let range = NSRange(html.startIndex..., in: html); let rows = regex.matches(in: html, range: range).compactMap { match -> [String]? in guard let urlRange = Range(match.range(at: 1), in: html), let titleRange = Range(match.range(at: 2), in: html) else { return nil }; let title = clean(String(html[titleRange])); guard title.count > 2 else { return nil }; return [title, String(html[urlRange])] }; guard !rows.isEmpty else { return [] }; return [HTMLImportTable(name: "Linked objects", headers: ["Title", "Source URL"], rows: rows)] }
    private func captureMatches(_ pattern: String, in string: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                guard let captureRange = Range(match.range(at: index), in: string) else { return "" }
                return String(string[captureRange])
            }
        }
    }
    private func matches(_ pattern: String, in string: String) -> [String] { guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }; let range = NSRange(string.startIndex..., in: string); return regex.matches(in: string, range: range).compactMap { match in guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: string) else { return nil }; return String(string[range]) } }
    private func clean(_ value: String) -> String { var value = value.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression); let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]; for (entity, replacement) in entities { value = value.replacingOccurrences(of: entity, with: replacement) }; return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum HTMLImportError: LocalizedError { case noObjects; var errorDescription: String? { "No importable tables or repeated linked objects were found in this HTML." } }
