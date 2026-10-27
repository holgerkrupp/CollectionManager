import Foundation

/// Derived value snapshots are prepared outside the UI actor and published
/// together only when their items/locale generation is still current.
nonisolated struct ItemDerivedState: Sendable {
    let searchIndex: ItemSearchIndex
    let brands: [String]
    let hasDateTags: Bool
    let stats: (stored: Int, consumed: Int, wanted: Int)

    static func prepare(items: [CollectionItem], locale: Locale = .current) throws -> Self {
        try Task.checkCancellation()
        var brands = Set<String>()
        var hasDateTags = false
        var stored = 0, consumed = 0, wanted = 0
        for (offset, item) in items.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            if !item.brand.isEmpty { brands.insert(item.brand) }
            if !item.dateTags.isEmpty { hasDateTags = true }
            if item.state == .stored { stored += 1 }
            if item.state == .consumed { consumed += 1 }
            if item.state == .wanted { wanted += 1 }
        }
        try Task.checkCancellation()
        let sortedBrands = brands.sorted()
        let index = try ItemSearchIndex.prepared(items: items, locale: locale)
        try Task.checkCancellation()
        return Self(searchIndex: index, brands: sortedBrands, hasDateTags: hasDateTags,
                    stats: (stored, consumed, wanted))
    }
}
