import AppIntents
import Foundation

// Every intent touches the SwiftData store owned by the app process, so none
// of them may run in an extension (iOS 27 `allowedExecutionTargets`).

// MARK: - Status

struct ItemStatusEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Status"
    static let defaultQuery = ItemStatusQuery()

    let id: String
    let name: String
    let symbol: String

    @MainActor init(status: CollectionStatus) {
        id = status.id
        name = status.name
        symbol = status.symbol
    }

    var state: ItemState { ItemState(rawValue: id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
}

/// Statuses are configured per collection, so suggestions follow the
/// collection or item already chosen in the intent when there is one.
struct ItemStatusQuery: EntityQuery {
    @Dependency private var store: AppStore
    @IntentParameterDependency<AddItemIntent>(\.$collection) private var addItem
    @IntentParameterDependency<SetItemStatusIntent>(\.$item) private var setItemStatus

    @MainActor func entities(for identifiers: [String]) async throws -> [ItemStatusEntity] {
        let wanted = Set(identifiers)
        return allStatuses().filter { wanted.contains($0.id) }
    }

    @MainActor func suggestedEntities() async throws -> [ItemStatusEntity] {
        let collectionID = addItem?.collection.id ?? setItemStatus?.item.collectionID
        if let collectionID, let collection = store.intentCollections().first(where: { $0.id == collectionID }) {
            return collection.statuses.map(ItemStatusEntity.init)
        }
        return allStatuses()
    }

    /// Every status any collection defines, with the first name winning when
    /// collections rename the same built-in status differently.
    @MainActor private func allStatuses() -> [ItemStatusEntity] {
        var seen = Set<String>()
        return (store.intentCollections().flatMap(\.statuses) + CollectionStatus.defaults)
            .filter { seen.insert($0.id).inserted }
            .map(ItemStatusEntity.init)
    }
}

// MARK: - Errors

nonisolated enum CollectionIntentError: Error, CustomLocalizedStringResourceConvertible {
    case itemNotFound
    case notEditable(String)
    case statusUnavailable(String, String)
    case duplicateItem(String, String)
    case iCloudUnavailable
    case syncFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .itemNotFound: "That item is no longer in your collections."
        case .notEditable(let collection): "You can view “\(collection)” but not change it. Ask its owner to make you an editor."
        case .statusUnavailable(let status, let collection): "“\(collection)” doesn’t have a “\(status)” status."
        case .duplicateItem(let title, let collection): "“\(collection)” already has an item called “\(title)”."
        case .iCloudUnavailable: "Sign in to iCloud to sync collections."
        case .syncFailed(let message): "Sync didn’t finish: \(message)"
        }
    }
}

// MARK: - Open

struct OpenCollectionIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Collection"
    static let description = IntentDescription("Shows a collection in Collection Manager.")
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Collection") var target: CollectionEntity
    @Dependency private var store: AppStore

    @MainActor func perform() async throws -> some IntentResult {
        store.open(collectionID: target.id)
        return .result()
    }
}

struct OpenItemIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Item"
    static let description = IntentDescription("Shows an item’s details in Collection Manager.")
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Item") var target: ItemEntity
    @Dependency private var store: AppStore

    @MainActor func perform() async throws -> some IntentResult {
        store.open(itemID: target.id)
        return .result()
    }
}

// MARK: - Add

struct AddItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Item"
    static let description = IntentDescription("Adds an item to one of your collections.")
    static let supportedModes: IntentModes = .background
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Collection") var collection: CollectionEntity
    @Parameter(title: "Title") var itemTitle: String
    @Parameter(title: "Status") var status: ItemStatusEntity?
    @Parameter(title: "Brand") var brand: String?
    @Parameter(title: "Quantity", default: 1, inclusiveRange: (1, 999)) var quantity: Int
    @Parameter(title: "Tags") var tags: [String]?
    @Dependency private var store: AppStore

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$itemTitle) to \(\.$collection)") {
            \.$status
            \.$brand
            \.$quantity
            \.$tags
        }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<ItemEntity> & ProvidesDialog {
        guard let model = store.intentCollections().first(where: { $0.id == collection.id }), model.role.canEdit else {
            throw CollectionIntentError.notEditable(collection.name)
        }
        let state = status?.state ?? model.statuses.first.map { ItemState(rawValue: $0.id) } ?? .wanted
        guard model.statuses.contains(where: { $0.id == state.rawValue }) else {
            throw CollectionIntentError.statusUnavailable(status?.name ?? state.label, model.name)
        }
        guard let item = store.addItem(title: itemTitle, brand: brand ?? "", variant: "", description: "", state: state, quantity: quantity, tags: tags ?? [], collectionID: model.id) else {
            throw CollectionIntentError.duplicateItem(itemTitle, model.name)
        }
        return .result(value: ItemEntity(item: item, collection: model), dialog: "Added \(item.title) to \(model.name).")
    }
}

// MARK: - Status changes

extension UndoableIntent {
    /// Registers the reverse of a status change with the undo manager the
    /// system provides, so the person can undo it from the app afterwards.
    @MainActor func registerUndo(restoring snapshot: [CollectionItem], in store: AppStore) {
        guard !snapshot.isEmpty, let undoManager else { return }
        undoManager.registerUndo(withTarget: store) { $0.restoreStates(snapshot) }
        undoManager.setActionName("Change Status")
    }
}

struct SetItemStatusIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Set Item Status"
    static let description = IntentDescription("Moves an item to another status, such as In Storage or Consumed.")
    static let supportedModes: IntentModes = .background
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Item") var item: ItemEntity
    @Parameter(title: "Status") var status: ItemStatusEntity
    @Dependency private var store: AppStore

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$item) to \(\.$status)")
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<ItemEntity> & ProvidesDialog {
        guard item.stateID != status.id else {
            return .result(value: item, dialog: "\(item.title) is already \(status.name).")
        }
        let previous = store.setState(status.state, forItemIDs: [item.id])
        guard !previous.isEmpty else {
            guard let collection = store.intentCollections().first(where: { $0.id == item.collectionID }) else { throw CollectionIntentError.itemNotFound }
            if !collection.role.canEdit { throw CollectionIntentError.notEditable(collection.name) }
            throw CollectionIntentError.statusUnavailable(status.name, collection.name)
        }
        registerUndo(restoring: previous, in: store)
        let updated = store.item(id: item.id).flatMap { store.itemEntities(for: [$0]).first } ?? item
        return .result(value: updated, dialog: "Moved \(item.title) to \(status.name).")
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct SetStatusForItemsIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Set Status for Items"
    static let description = IntentDescription("Moves several items to the same status at once. Items in collections without that status are left unchanged.")
    static let supportedModes: IntentModes = .background
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    // An EntityCollection carries identifiers only, so a large selection from
    // Shortcuts is not resolved into full entities just to read their IDs.
    @Parameter(title: "Items") var items: EntityCollection<ItemEntity>
    @Parameter(title: "Status") var status: ItemStatusEntity
    @Dependency private var store: AppStore

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$items) to \(\.$status)")
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let previous = store.setState(status.state, forItemIDs: items.identifiers)
        registerUndo(restoring: previous, in: store)
        return .result(dialog: "Moved \(previous.count) of \(items.count) items to \(status.name).")
    }
}

// MARK: - Delete

struct DeleteItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Item"
    static let description = IntentDescription("Removes an item, with its ratings and comments, from its collection.")
    static let supportedModes: IntentModes = .background
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Item") var item: ItemEntity
    @Dependency private var store: AppStore

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = store.item(id: item.id) else { throw CollectionIntentError.itemNotFound }
        if !systemConfirmsDeletion {
            try await requestConfirmation(dialog: "Delete \(item.title)? This can’t be undone.")
        }
        guard await store.deleteItem(model) else {
            // The error reaches the person through the intent; don't also
            // leave an alert waiting for the next time the app is opened.
            store.itemActionError = nil
            throw CollectionIntentError.notEditable(item.collectionName)
        }
        return .result(dialog: "Deleted \(item.title).")
    }

    /// From iOS 27 the system asks on its own before an intent deletes a
    /// shared entity (OwnershipProvidingEntity), so asking here as well would
    /// show two prompts.
    private var systemConfirmsDeletion: Bool {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) { return item.isShared }
        return false
    }
}

// MARK: - Sync

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct SyncCollectionsIntent: AppIntent, LongRunningIntent {
    static let title: LocalizedStringResource = "Sync Collections"
    static let description = IntentDescription("Exchanges changes with the people you share collections with through iCloud.")
    static let supportedModes: IntentModes = .background
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Dependency private var store: AppStore

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard CloudKitSharingService.isAvailable else { throw CollectionIntentError.iCloudUnavailable }
        progress.totalUnitCount = 1
        // A CloudKit round trip across many shared collections can outlast
        // the normal intent time limit, so it runs as a long-running task.
        let store = store
        let failure = try await performBackgroundTask { @MainActor in
            await store.syncCollections()
            return store.syncError
        }
        progress.completedUnitCount = 1
        if let failure { throw CollectionIntentError.syncFailed(failure) }
        return .result(dialog: "Your collections are up to date.")
    }
}

// MARK: - App Shortcuts

struct CollectionManagerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddItemIntent(), phrases: [
            "Add an item to \(\.$collection) in \(.applicationName)",
            "Add an item in \(.applicationName)"
        ], shortTitle: "Add Item", systemImageName: "plus.circle")
        AppShortcut(intent: SetItemStatusIntent(), phrases: [
            "Change an item’s status in \(.applicationName)",
            "Update an item in \(.applicationName)"
        ], shortTitle: "Set Status", systemImageName: "checkmark.circle")
        AppShortcut(intent: OpenCollectionIntent(), phrases: [
            "Open \(\.$target) in \(.applicationName)",
            "Show a collection in \(.applicationName)"
        ], shortTitle: "Open Collection", systemImageName: "square.stack.3d.up")
    }
}
