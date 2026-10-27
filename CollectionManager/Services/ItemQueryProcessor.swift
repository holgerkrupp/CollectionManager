import Foundation

/// Immutable snapshots cross the task boundary; no context, observable store,
/// shared formatter or persistent model is accessed by query preparation.
nonisolated struct ItemQueryRequest: Sendable {
    let items: [CollectionItem]
    let searchIndex: ItemSearchIndex
    let searchText: String
    let selectedState: ItemState?
    let selectedBrand: String?
    let sort: ItemSort
    let metadataFields: [MetadataFieldDefinition]
    let locale: Locale

    init(items: [CollectionItem], searchIndex: ItemSearchIndex, searchText: String,
         selectedState: ItemState? = nil, selectedBrand: String? = nil,
         sort: ItemSort = .updatedDescending, metadataFields: [MetadataFieldDefinition] = [],
         locale: Locale = .current) {
        self.items = items
        self.searchIndex = searchIndex
        self.searchText = searchText
        self.selectedState = selectedState
        self.selectedBrand = selectedBrand
        self.sort = sort
        self.metadataFields = metadataFields
        self.locale = locale
    }
}

nonisolated enum ItemQueryProcessor {
    /// Call from Task.detached. Cancel obsolete requests and publish only the
    /// result whose collection/query generation still matches the UI owner.
    static func evaluate(_ request: ItemQueryRequest) throws -> [CollectionItem] {
        try Task.checkCancellation()
        let query = ItemSearchIndex.normalizedQuery(request.searchText)
        var filtered: [CollectionItem] = []
        filtered.reserveCapacity(request.items.count)
        for (offset, item) in request.items.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            guard request.selectedState == nil || item.state == request.selectedState,
                  request.selectedBrand == nil || item.brand == request.selectedBrand else { continue }
            if query.isEmpty || request.searchIndex.matches(itemID: item.id, normalizedQuery: query) {
                filtered.append(item)
            }
        }
        try Task.checkCancellation()
        let sorted: [CollectionItem]
        switch request.sort {
        case .updatedDescending:
            sorted = filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .titleAscending:
            sorted = filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .dateAscending:
            sorted = filtered.sorted { dateSorts($0, before: $1, ascending: true) }
        case .dateDescending:
            sorted = filtered.sorted { dateSorts($0, before: $1, ascending: false) }
        case .metadata(let fieldID, let direction):
            if let field = request.metadataFields.first(where: { $0.id == fieldID }) {
                // A task-local formatter preserves locale parsing semantics
                // without moving a mutable cached formatter between executors.
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.locale = request.locale
                sorted = filtered.sorted { metadataSorts($0, before: $1, field: field, direction: direction, formatter: formatter) }
            } else {
                sorted = filtered.sorted { $0.updatedAt > $1.updatedAt }
            }
        }
        // Swift's sort comparator cannot throw. Cancellation still prevents an
        // obsolete completed sort from being published by the caller.
        try Task.checkCancellation()
        return sorted
    }

    private static func dateSorts(_ lhs: CollectionItem, before rhs: CollectionItem, ascending: Bool) -> Bool {
        switch (lhs.earliestDateTag, rhs.earliestDateTag) {
        case (nil, nil): return titleSorts(lhs, before: rhs)
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return ascending ? left < right : left > right
        }
    }

    private static func metadataSorts(_ lhs: CollectionItem, before rhs: CollectionItem,
                                      field: MetadataFieldDefinition, direction: SortDirection,
                                      formatter: NumberFormatter) -> Bool {
        let left = lhs.metadata[field.storageKey], right = rhs.metadata[field.storageKey]
        switch field.type {
        case .text, .color:
            return textValuesSort(metadataText(left), metadataText(right), lhs: lhs, rhs: rhs, direction: direction)
        case .number:
            return valuesSort(metadataNumber(left, formatter: formatter), metadataNumber(right, formatter: formatter), lhs: lhs, rhs: rhs, direction: direction)
        case .date:
            return valuesSort(metadataDate(left), metadataDate(right), lhs: lhs, rhs: rhs, direction: direction)
        case .boolean:
            return valuesSort(metadataBoolean(left), metadataBoolean(right), lhs: lhs, rhs: rhs, direction: direction)
        }
    }

    private static func titleSorts(_ lhs: CollectionItem, before rhs: CollectionItem) -> Bool {
        lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private static func valuesSort<Value: Comparable>(_ left: Value?, _ right: Value?, lhs: CollectionItem,
                                                       rhs: CollectionItem, direction: SortDirection) -> Bool {
        switch (left, right) {
        case (nil, nil): return titleSorts(lhs, before: rhs)
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?):
            if left == right { return titleSorts(lhs, before: rhs) }
            return direction == .ascending ? left < right : left > right
        }
    }

    private static func textValuesSort(_ left: String?, _ right: String?, lhs: CollectionItem,
                                      rhs: CollectionItem, direction: SortDirection) -> Bool {
        switch (left, right) {
        case (nil, nil): return titleSorts(lhs, before: rhs)
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?):
            let comparison = left.localizedStandardCompare(right)
            if comparison == .orderedSame { return titleSorts(lhs, before: rhs) }
            return direction == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private static func metadataText(_ value: MetadataValue?) -> String? {
        guard let value else { return nil }
        let text = value.displayValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func metadataNumber(_ value: MetadataValue?, formatter: NumberFormatter) -> Double? {
        switch value {
        case .integer(let number): return Double(number)
        case .decimal(let number): return number
        case .string(let text): return formatter.number(from: text)?.doubleValue
        default: return nil
        }
    }

    private static func metadataDate(_ value: MetadataValue?) -> Date? {
        if case .date(let date)? = value { return date }
        return nil
    }

    private static func metadataBoolean(_ value: MetadataValue?) -> Int? {
        switch value {
        case .boolean(let value): return value ? 1 : 0
        case .integer(let value): return value == 0 ? 0 : 1
        case .decimal(let value): return value == 0 ? 0 : 1
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y", "1", "on": return 1
            case "false", "no", "n", "0", "off": return 0
            default: return nil
            }
        default: return nil
        }
    }
}
