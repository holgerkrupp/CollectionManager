import Foundation

/// Derived text only: no image bytes, source-provider payloads or persisted state.
/// Rebuild when the selected items or locale change, never for each keypress.
struct ItemSearchIndex: Sendable {
    private var textByID: [UUID: String] = [:]

    init(items: [CollectionItem] = []) { rebuild(items: items) }

    mutating func rebuild(items: [CollectionItem]) {
        textByID = Dictionary(items.map { ($0.id, Self.searchableText(for: $0)) }, uniquingKeysWith: { _, last in last })
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

    static func searchableText(for item: CollectionItem) -> String {
        ([item.title, item.brand, item.variant, item.itemDescription, item.barcode?.value ?? ""]
         + item.tags + item.metadata.values.map(\.displayValue)).joined(separator: " ").lowercased()
    }
}
