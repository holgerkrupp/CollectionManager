import Foundation

struct ImportDraft: Identifiable, Sendable { let id = UUID(); var title: String; var brand: String; var variant: String; var description: String; var state: ItemState; var quantity: Int; var tags: [String]; var barcode: Barcode?; var sourceIdentifier: String? = nil }

struct CollectionImporter {
    func parseCSV(_ data: Data) throws -> [ImportDraft] {
        guard var text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        if text.first == "\u{feff}" { text.removeFirst() }
        let rows = parseRows(text).filter { $0.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }
        guard let header = rows.first else { return [] }
        let columns = header.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }

        return rows.dropFirst().compactMap { values in
            func value(_ names: [String]) -> String {
                for name in names {
                    if let index = columns.firstIndex(of: name), index < values.count {
                        return values[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return ""
            }

            let title = value(["title", "name", "product", "product_name"])
            guard !title.isEmpty else { return nil }
            return ImportDraft(
                title: title,
                brand: value(["brand", "manufacturer"]),
                variant: value(["variant", "flavour", "flavor"]),
                description: value(["description", "notes"]),
                state: value(["state", "status"]).lowercased().isEmpty ? .wanted : ItemState(rawValue: value(["state", "status"]).lowercased()),
                quantity: max(Int(value(["quantity", "count"])) ?? 1, 1),
                tags: TagUtilities.splitTags(value(["tags", "labels"])),
                barcode: Barcode(rawValue: value(["barcode", "ean", "upc"]))
            )
        }
    }

    private func parseRows(_ text: String) -> [[String]] {
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
            } else if character == "," && !isQuoted {
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
