import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation

// Entities are nonisolated so the system can build and read them off the main
// actor. Their initializers read MainActor domain types, so they stay on it.

struct CollectionEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Collection", numericFormat: "\(placeholder: .int) collections")
    static let defaultQuery = CollectionEntityQuery()

    let id: UUID
    let icon: String
    let isShared: Bool

    @Property(title: "Name") var name: String
    @Property(title: "Category") var category: String
    @Property(title: "Description") var subtitle: String

    @MainActor init(collection: CollectionModel) {
        id = collection.id
        icon = collection.icon
        isShared = !collection.sharedWith.isEmpty || collection.role != .owner
        name = collection.name
        category = collection.category.name
        subtitle = collection.caption
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)", image: .init(systemName: icon))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = [category, subtitle].filter { !$0.isEmpty }.joined(separator: " · ")
        return attributes
    }
}

struct ItemEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Collection Item", numericFormat: "\(placeholder: .int) items")
    static let defaultQuery = ItemEntityQuery()

    let id: UUID
    let collectionID: UUID
    let stateID: String
    let symbol: String
    let isShared: Bool
    let details: String

    @Property(title: "Title") var title: String
    @Property(title: "Brand") var brand: String
    @Property(title: "Variant") var variant: String
    @Property(title: "Status") var status: String
    @Property(title: "Quantity") var quantity: Int
    @Property(title: "Tags") var tags: [String]
    @Property(title: "Collection") var collectionName: String
    @Property(title: "Barcode") var barcode: String?
    @Property(title: "Last Updated") var updatedAt: Date

    @MainActor init(item: CollectionItem, collection: CollectionModel?) {
        let status = collection?.status(for: item.state) ?? CollectionStatus.fallback(for: item.state)
        id = item.id
        collectionID = item.collectionID
        stateID = item.state.rawValue
        symbol = status.symbol
        isShared = collection.map { !$0.sharedWith.isEmpty || $0.role != .owner } ?? false
        details = item.itemDescription
        title = item.title
        brand = item.brand
        variant = item.variant
        self.status = status.name
        quantity = item.quantity
        tags = item.tags
        collectionName = collection?.name ?? ""
        barcode = item.barcode?.value
        updatedAt = item.updatedAt
    }

    private var byline: String { [brand, variant].filter { !$0.isEmpty }.joined(separator: " · ") }

    var displayRepresentation: DisplayRepresentation {
        let subtitle = [status, collectionName].filter { !$0.isEmpty }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: .init(systemName: symbol))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = [byline, status, details].filter { !$0.isEmpty }.joined(separator: "\n")
        attributes.keywords = tags + [brand, collectionName, barcode].compactMap { $0 }.filter { !$0.isEmpty }
        attributes.contentModificationDate = updatedAt
        return attributes
    }

    /// Plain text handed to other apps when Siri or Shortcuts moves an item
    /// across apps.
    var plainTextSummary: String {
        var lines = [title]
        if !byline.isEmpty { lines.append(byline) }
        lines.append("Status: \(status)")
        if quantity > 1 { lines.append("Quantity: \(quantity)") }
        if !tags.isEmpty { lines.append("Tags: " + tags.joined(separator: ", ")) }
        if !details.isEmpty { lines.append(details) }
        return lines.joined(separator: "\n")
    }
}

extension ItemEntity: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { $0.plainTextSummary }
    }
}

// iOS 27: both entities are keyed by the UUID that also names their CloudKit
// records, so the identifier is already the same on every device. Shared
// collections report their ownership so the system asks before an intent
// changes or deletes something other people can see.

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension CollectionEntity: SyncableEntity, OwnershipProvidingEntity {
    var ownership: EntityOwnership { isShared ? .shared : [] }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension ItemEntity: SyncableEntity, OwnershipProvidingEntity {
    var ownership: EntityOwnership { isShared ? .shared : [] }
}

// MARK: - Queries

struct CollectionEntityQuery: EntityStringQuery {
    @Dependency private var store: AppStore

    @MainActor func entities(for identifiers: [UUID]) async throws -> [CollectionEntity] {
        let wanted = Set(identifiers)
        return store.intentCollections().filter { wanted.contains($0.id) }.map(CollectionEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [CollectionEntity] {
        store.intentCollections().filter { $0.name.localizedStandardContains(string) }.map(CollectionEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [CollectionEntity] {
        store.intentCollections().map(CollectionEntity.init)
    }
}

struct ItemEntityQuery: EntityStringQuery {
    @Dependency private var store: AppStore

    @MainActor func entities(for identifiers: [UUID]) async throws -> [ItemEntity] {
        store.itemEntities(for: identifiers.compactMap(store.item(id:)))
    }

    @MainActor func entities(matching string: String) async throws -> [ItemEntity] {
        let matches = store.intentItems().filter { item in
            ([item.title, item.brand, item.variant, item.barcode?.value ?? ""] + item.tags)
                .contains { $0.localizedStandardContains(string) }
        }
        return store.itemEntities(for: matches)
    }

    @MainActor func suggestedEntities() async throws -> [ItemEntity] {
        let recent = store.intentItems().sorted { $0.updatedAt > $1.updatedAt }.prefix(20)
        return store.itemEntities(for: Array(recent))
    }
}

// iOS 27: the system can ask the app to rebuild its part of the Spotlight
// index, for example after a restore, instead of waiting for the next launch.

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension CollectionEntityQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities(for: identifiers))
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        try await CSSearchableIndex.default().indexAppEntities(suggestedEntities())
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension ItemEntityQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities(for: identifiers))
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await store.updateSpotlightIndex()
    }
}

// MARK: - Spotlight

extension AppStore {
    func itemEntities(for items: [CollectionItem]) -> [ItemEntity] {
        let collectionsByID = Dictionary(uniqueKeysWithValues: intentCollections().map { ($0.id, $0) })
        return items.map { ItemEntity(item: $0, collection: collectionsByID[$0.collectionID]) }
    }

    /// Rebuilds the app's Spotlight entries from the local store and refreshes
    /// the collection names App Shortcut phrases can use. Clearing first drops
    /// entries for items another participant deleted while the app was closed.
    func updateSpotlightIndex() async {
        let index = CSSearchableIndex.default()
        let collections = intentCollections().map(CollectionEntity.init)
        let items = itemEntities(for: intentItems())
        try? await index.deleteAppEntities(ofType: CollectionEntity.self)
        try? await index.deleteAppEntities(ofType: ItemEntity.self)
        try? await index.indexAppEntities(collections)
        try? await index.indexAppEntities(items)
        CollectionManagerShortcuts.updateAppShortcutParameters()
    }

    func indexInSpotlight(_ items: [CollectionItem]) {
        guard !items.isEmpty else { return }
        let entities = itemEntities(for: items)
        Task { try? await CSSearchableIndex.default().indexAppEntities(entities) }
    }

    func removeFromSpotlight(itemIDs: [UUID]) {
        Task { try? await CSSearchableIndex.default().deleteAppEntities(identifiedBy: itemIDs, ofType: ItemEntity.self) }
    }
}
