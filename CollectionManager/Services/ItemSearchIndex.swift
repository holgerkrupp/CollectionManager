import Foundation

/// Derived text only: no image bytes, source-provider payloads or persisted state.
/// Rebuild when the selected items or locale change, never for each keypress.
nonisolated struct ItemSearchIndex: Sendable {
    private var textByID: [UUID: String] = [:]

    init(items: [CollectionItem] = []) { rebuild(items: items) }

    mutating func rebuild(items: [CollectionItem]) {
        textByID = Dictionary(items.map { ($0.id, Self.searchableText(for: $0)) }, uniquingKeysWith: { _, last in last })
    }

    static func prepared(items: [CollectionItem], locale: Locale = .current) throws -> Self {
        var index = Self()
        index.textByID.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            index.textByID[item.id] = searchableText(for: item, locale: locale)
        }
        try Task.checkCancellation()
        return index
    }

    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `query` is normalized once by the caller. Missing IDs fail closed rather
    /// than accidentally matching a row from an earlier selected collection.
    func matches(itemID: UUID, normalizedQuery query: String) -> Bool {
        guard let text = textByID[itemID] else { return false }
        return query.isEmpty || text.contains(query)
    }

    static func searchableText(for item: CollectionItem, locale: Locale = .current) -> String {
        // Presentation formatting must not remove the original numeric search
        // spelling when a locale uses grouping or a different decimal mark.
        let metadata = item.metadata.values.flatMap { value -> [String] in
            let display = value.displayValue(locale: locale)
            switch value {
            case .integer(let number): return [display, String(number)]
            case .decimal(let number): return [display, String(number)]
            case .boolean(let flag): return [display, flag ? "Yes" : "No"]
            default: return [display]
            }
        }
        return ([item.title, item.brand, item.variant, item.itemDescription, item.barcode?.value ?? ""]
         + item.tags + metadata).joined(separator: " ").lowercased()
    }
}
