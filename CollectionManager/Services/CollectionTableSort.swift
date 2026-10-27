import Foundation

nonisolated struct CollectionTableSortIdentity: Hashable, Sendable {
    let visibleItemsRevision: UInt64
    let sortOrder: [KeyPathComparator<CollectionItem>]
    let usesColumnSort: Bool
    let collectionID: UUID
}

nonisolated struct CollectionTableSortCache: Sendable {
    let identity: CollectionTableSortIdentity
    let sortedRows: [CollectionItem]

    func rows(for current: CollectionTableSortIdentity, fallback: [CollectionItem]) -> [CollectionItem] {
        guard current.usesColumnSort, identity == current else { return fallback }
        return sortedRows
    }
}

nonisolated enum CollectionTableSort {
    /// Preserve Foundation's existing comparator values and stable ordering.
    /// Invoke on a detached task; no SwiftData or observable state crosses it.
    static func sorted(_ snapshot: [CollectionItem], using order: [KeyPathComparator<CollectionItem>]) throws -> [CollectionItem] {
        try Task.checkCancellation()
        let result = snapshot.sorted(using: order)
        try Task.checkCancellation()
        return result
    }
}
