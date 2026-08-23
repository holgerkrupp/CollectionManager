import Foundation
import CloudKit
import Observation
import SwiftData

@MainActor @Observable final class AppStore {
    private var repository: CollectionRepository?
    private var backgroundRepository: CollectionBackgroundRepository?
    private var modelContext: ModelContext?
    var collections: [CollectionModel] = []
    var selectedCollection: CollectionModel?
    var items: [CollectionItem] = [] { didSet { rebuildDerivedItemState() } }
    var webSyncs: [WebSyncRecord] = []
    var searchText = "" { didSet { rebuildVisibleItems() } }
    var selectedState: ItemState? { didSet { rebuildVisibleItems() } }
    var selectedBrand: String? { didSet { rebuildVisibleItems() } }
    var itemSort: ItemSort = .updatedDescending { didSet { rebuildVisibleItems() } }
    private(set) var visibleItems: [CollectionItem] = []
    private(set) var brands: [String] = []
    private(set) var hasDateTags = false
    private(set) var stats: (stored: Int, consumed: Int, wanted: Int) = (0, 0, 0)
    private(set) var pendingItemOperations: Set<UUID> = []
    private(set) var isBulkOperationInProgress = false
    var isLoading = false
    var lastWebSyncMessage: String?
    var syncState: CollectionSyncState = .idle
    var syncError: String?
    var pendingSyncCount = 0
    private var syncRequestedWhileSyncing = false
    func configure(context: ModelContext, container: ModelContainer) { guard repository == nil else { return }; modelContext = context; repository = CollectionRepository(context: context); backgroundRepository = CollectionBackgroundRepository(container: container) }
    func load() { loadCollections(); loadSelectedCollection() }
    func loadCollections() {
        guard let repository else { return }
        isLoading = true
        collections = repository.collections()
        LocalNotificationPreferences.migrateLegacySettings(to: collections.map(\.id))
        selectedCollection = selectedCollection.flatMap { selected in collections.first(where: { $0.id == selected.id }) } ?? collections.first
        if case .metadata(let fieldID, _) = itemSort,
           selectedCollection?.metadataFields.contains(where: { $0.id == fieldID }) != true {
            itemSort = .updatedDescending
        }
        isLoading = false
    }
    func loadSelectedCollection() {
        guard let repository, let collectionID = selectedCollection?.id else { items = []; webSyncs = []; return }
        isLoading = true
        items = repository.items(in: collectionID)
        webSyncs = repository.webSyncs(for: collectionID)
        isLoading = false
    }
    func loadSelectedCollectionInBackground() async {
        guard let repository, let backgroundRepository, let collectionID = selectedCollection?.id else { items = []; webSyncs = []; return }
        isLoading = true
        let loadedItems = await backgroundRepository.items(in: collectionID)
        guard selectedCollection?.id == collectionID else { return }
        if items != loadedItems { items = loadedItems }
        webSyncs = repository.webSyncs(for: collectionID)
        isLoading = false
    }
    func select(_ collectionID: UUID?) { guard let collectionID, let collection = collections.first(where: { $0.id == collectionID }), selectedCollection?.id != collectionID else { return }; selectedCollection = collection; selectedState = nil; selectedBrand = nil; itemSort = .updatedDescending; Task { await loadSelectedCollectionInBackground() } }
    func addCollection(name: String, icon: String, subtitle: String, category: CollectionCategory = .custom) { repository?.addCollection(name: name, icon: icon, subtitle: subtitle, category: category); loadCollections(); loadSelectedCollection() }
    func updateCollection(_ collection: CollectionModel) { repository?.updateCollection(collection); loadCollections(); loadSelectedCollection() }
    func addMetadataFields(_ fields: [MetadataFieldDefinition]) {
        guard var collection = selectedCollection, collection.role.canEdit, !fields.isEmpty else { return }
        let existingIDs = Set(collection.metadataFields.map(\.id))
        collection.metadataFields.append(contentsOf: fields.filter { !existingIDs.contains($0.id) })
        updateCollection(collection)
    }
    func deleteCollection(_ collection: CollectionModel) async {
        guard collection.role.canDelete, let backgroundRepository else { return }
        let previousCollections = collections
        collections.removeAll { $0.id == collection.id }
        if selectedCollection?.id == collection.id {
            selectedCollection = collections.first
            items = []
            webSyncs = []
        }
        await Task.yield()
        if await backgroundRepository.deleteCollection(id: collection.id) {
            if selectedCollection != nil { await loadSelectedCollectionInBackground() }
        } else {
            collections = previousCollections
            selectedCollection = collections.first(where: { $0.id == collection.id }) ?? collections.first
            await loadSelectedCollectionInBackground()
        }
    }
    func addItem(title: String, brand: String, variant: String, description: String, state: ItemState, quantity: Int, tags: [String], metadata: [String: MetadataValue] = [:], barcode: Barcode? = nil, imageData: Data? = nil, sourceIdentifier: String? = nil, sourceSnapshot: ProductSourceSnapshot? = nil) {
        guard let collectionID = selectedCollection?.id else { return }
        let item = CollectionItem(id: UUID(), collectionID: collectionID, title: title, brand: brand, variant: variant, itemDescription: description, state: state, quantity: quantity, barcode: barcode, createdAt: .now, updatedAt: .now, consumedAt: state == .consumed ? .now : nil, tags: tags, metadata: metadata, imageSystemName: "shippingbox.fill", imageData: imageData, importSourceKey: sourceIdentifier, sourceSnapshot: sourceSnapshot)
        guard repository?.addItem(item) == true else { return }
        items.insert(item, at: 0)
        Task { await syncCollections() }
    }
    @discardableResult func bulkUpdateState(for filteredItems: [CollectionItem], to state: ItemState) -> Int {
        guard let repository, let collection = selectedCollection, collection.role.canEdit, !filteredItems.isEmpty else { return 0 }
        guard filteredItems.allSatisfy({ $0.collectionID == collection.id }) else { return 0 }
        let changed = repository.bulkUpdateState(for: Set(filteredItems.map(\.id)), in: collection.id, to: state)
        if changed > 0 { loadSelectedCollection() }
        return changed
    }
    func importDrafts(_ drafts: [ImportDraft]) { guard let repository, let collectionID = selectedCollection?.id else { return }; let entries = drafts.map { draft in (draft: draft, sourceKey: draft.sourceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? draft.sourceIdentifier!.trimmingCharacters(in: .whitespacesAndNewlines) : "\(draft.title)|\(draft.brand)|\(draft.variant)") }; repository.importDrafts(entries, collectionID: collectionID); loadSelectedCollection() }
    func deduplicateItems() -> Int {
        guard let repository, let collectionID = selectedCollection?.id else { return 0 }
        let removed = repository.deduplicateItems(in: collectionID)
        loadSelectedCollection()
        if removed > 0 { Task { await syncCollections() } }
        return removed
    }
    func deduplicateImportedItems() -> Int { deduplicateItems() }
    func deleteAllImportedItems() -> Int { guard let repository, let collectionID = selectedCollection?.id else { return 0 }; let removed = repository.deleteAllImportedItems(in: collectionID); loadSelectedCollection(); return removed }
    func applyTagRules(_ options: TagGenerationOptions) -> Int { guard let repository, let collectionID = selectedCollection?.id else { return 0 }; let changed = repository.applyTagRules(options, in: collectionID); loadSelectedCollection(); return changed }
    func applyMergedTagsToExistingItems() -> Int { guard let repository, let collectionID = selectedCollection?.id else { return 0 }; let changed = repository.applyMergedTags(in: collectionID); loadSelectedCollection(); return changed }
    func updateItem(_ item: CollectionItem, previousState: ItemState) { repository?.updateItem(item, previousState: previousState); replaceItem(item) }
    func setRating(_ value: Int?, for item: CollectionItem) { repository?.setRating(for: item, value: value, participant: .current); refreshItem(item.id) }
    @discardableResult func addComment(_ text: String, to item: CollectionItem) -> ItemComment? { let comment = repository?.addComment(to: item, text: text, participant: .current); refreshItem(item.id); return comment }
    func deleteItem(_ item: CollectionItem) async {
        guard item.state != .consumed, !pendingItemOperations.contains(item.id) else { return }
        pendingItemOperations.insert(item.id)
        items.removeAll { $0.id == item.id }
        // Let SwiftUI commit the optimistic removal/progress state before the
        // local SwiftData transaction starts.
        await Task.yield()
        let succeeded = await backgroundRepository?.deleteItem(id: item.id, collectionID: item.collectionID) ?? false
        if !succeeded { items.append(item) }
        pendingItemOperations.remove(item.id)
    }
    func deleteAllItems() async -> Int {
        guard let repository, let collectionID = selectedCollection?.id, !isBulkOperationInProgress else { return 0 }
        isBulkOperationInProgress = true
        let previousItems = items
        items = []
        await Task.yield()
        let removed = await backgroundRepository?.deleteAllItems(in: collectionID) ?? repository.deleteAllItems(in: collectionID)
        if removed == 0, !previousItems.isEmpty { loadSelectedCollection() }
        isBulkOperationInProgress = false
        return removed
    }
    func saveWebSync(_ sync: WebSyncRecord) { repository?.addWebSync(sync); if let id = selectedCollection?.id { webSyncs = repository?.webSyncs(for: id) ?? [] }; scheduleWebSync() }
    func updateWebSync(_ sync: WebSyncRecord) { repository?.updateWebSync(sync); if let id = selectedCollection?.id { webSyncs = repository?.webSyncs(for: id) ?? [] }; scheduleWebSync() }
    func deleteWebSync(_ sync: WebSyncRecord) { repository?.deleteWebSync(sync); if let id = selectedCollection?.id { webSyncs = repository?.webSyncs(for: id) ?? [] }; scheduleWebSync() }
    func syncWebSource(_ sync: WebSyncRecord) async { guard let modelContext else { return }; let result = await HTMLSyncCoordinator(context: modelContext).sync(sync); lastWebSyncMessage = result.error ?? "Sync complete: \(result.added) added, \(result.updated) updated"; scheduleWebSync(); await loadSelectedCollectionInBackground() }

    private func scheduleWebSync() {
        guard let modelContext else { return }
        WebSyncScheduler.schedule(context: modelContext)
    }
    func syncCollections() async {
        guard let repository, let backgroundRepository else { return }
        guard CloudKitSharingService.isAvailable else { return }
        guard syncState != .syncing else {
            syncRequestedWhileSyncing = true
            return
        }
        syncState = .syncing; syncError = nil
        let service = CloudKitSharingService()
        let localCollections = repository.collections()
        let mutations = repository.pendingMutations().map { CloudSyncMutation(id: $0.id, collectionID: $0.collectionID, itemID: $0.itemID, recordName: $0.recordName, recordType: $0.recordType, operation: $0.operation) }
        let payload = await backgroundRepository.syncPayload(collectionIDs: localCollections.map(\.id))
        let mutationIDs = Set(mutations.map(\.id))
        do {
            let snapshots = try await service.sync(collections: localCollections, items: payload.items, events: payload.events, mutations: mutations)
            // Remove the mutations that were just pushed before merging. The
            // merge may enqueue recovery mutations for data previously routed
            // to a participant's private duplicate, and those must survive for
            // the next shared-zone sync.
            repository.removeMutations(withIDs: mutationIDs)
            let notificationChanges = repository.merge(snapshots)
            LocalNotificationService.shared.scheduleSharedChanges(notificationChanges)
            if !repository.pendingMutations().isEmpty {
                syncRequestedWhileSyncing = true
            }
            repository.setSyncState(collectionID: selectedCollection?.id ?? localCollections.first?.id ?? UUID(), state: .idle, lastSyncedAt: .now)
            syncState = .idle; pendingSyncCount = 0; loadCollections(); await loadSelectedCollectionInBackground()
        } catch {
            syncState = .error; syncError = error.localizedDescription
            repository.markMutations(withIDs: mutationIDs, error: error)
            pendingSyncCount = repository.pendingMutations().count
            if let collectionID = selectedCollection?.id { repository.setSyncState(collectionID: collectionID, state: .error, error: error.localizedDescription) }
        }
        if syncRequestedWhileSyncing {
            syncRequestedWhileSyncing = false
            await syncCollections()
        }
    }
    func acceptShare(from url: URL) async { do { try await CloudKitSharingService().acceptShare(from: url); await syncCollections() } catch { syncState = .error; syncError = error.localizedDescription } }
    func acceptShare(metadata: CKShare.Metadata) async { do { try await CloudKitSharingService().acceptShare(metadata: metadata); await syncCollections() } catch { syncState = .error; syncError = error.localizedDescription } }
    var statuses: [CollectionStatus] {
        guard let configured = selectedCollection?.statuses, !configured.isEmpty else { return CollectionStatus.defaults }
        return configured
    }
    var itemSortLabel: String {
        guard case .metadata(let fieldID, let direction) = itemSort else { return itemSort.label }
        guard let field = selectedCollection?.metadataFields.first(where: { $0.id == fieldID }) else { return ItemSort.updatedDescending.label }
        return "\(field.name) (\(direction.label.lowercased()))"
    }
    func status(for state: ItemState, in collection: CollectionModel? = nil) -> CollectionStatus { (collection ?? selectedCollection)?.status(for: state) ?? CollectionStatus.fallback(for: state) }
    func barcodeStatus(_ barcode: Barcode) -> ItemState? { items.first(where: { $0.barcode == barcode })?.state }
    func productMatches(for barcode: Barcode, productName: String? = nil) -> [CollectionProductMatch] {
        guard let repository else { return [] }
        let collectionNames = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.name) })
        let normalizedName = productName.map(Self.normalizedText)
        let nameWords = normalizedName.map(Self.words) ?? []
        return collections.flatMap { collection in
            repository.items(in: collection.id).compactMap { item in
                var matchedBy: [String] = []
                if item.barcode == barcode { matchedBy.append("Barcode") }
                if let normalizedName, !normalizedName.isEmpty {
                    let itemWords = Self.words(item.title)
                    if Self.normalizedText(item.title) == normalizedName || nameWords.isSubset(of: itemWords) {
                        matchedBy.append("Name")
                    }
                    let normalizedTags = item.tags.map(Self.normalizedText)
                    let tagWords = Set(normalizedTags.flatMap(Self.words))
                    if normalizedTags.contains(normalizedName) || nameWords.isSubset(of: tagWords) {
                        matchedBy.append("Tags")
                    }
                }
                guard !matchedBy.isEmpty else { return nil }
                return CollectionProductMatch(id: item.id, collectionName: collectionNames[item.collectionID] ?? collection.name, itemTitle: item.title, state: item.state, status: collection.status(for: item.state), matchedBy: matchedBy)
            }
        }
    }
    private func rebuildDerivedItemState() {
        brands = Array(Set(items.lazy.map(\.brand).filter { !$0.isEmpty })).sorted()
        hasDateTags = items.contains { !$0.dateTags.isEmpty }
        var stored = 0, consumed = 0, wanted = 0
        for item in items {
            if item.state == .stored { stored += 1 }
            if item.state == .consumed { consumed += 1 }
            if item.state == .wanted { wanted += 1 }
        }
        stats = (stored, consumed, wanted)
        rebuildVisibleItems()
    }
    private func rebuildVisibleItems() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = items.filter { item in
            guard selectedState == nil || item.state == selectedState, selectedBrand == nil || item.brand == selectedBrand else { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([item.title, item.brand, item.variant, item.itemDescription, item.barcode?.value ?? ""] + item.tags + item.metadata.values.map(\.displayValue)).joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
        switch itemSort {
        case .updatedDescending: visibleItems = filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .titleAscending: visibleItems = filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .dateAscending: visibleItems = filtered.sorted { dateSorts($0, before: $1, ascending: true) }
        case .dateDescending: visibleItems = filtered.sorted { dateSorts($0, before: $1, ascending: false) }
        case .metadata(let fieldID, let direction):
            guard let field = selectedCollection?.metadataFields.first(where: { $0.id == fieldID }) else {
                visibleItems = filtered.sorted { $0.updatedAt > $1.updatedAt }
                return
            }
            visibleItems = filtered.sorted { metadataSorts($0, before: $1, field: field, direction: direction) }
        }
    }
    private func replaceItem(_ item: CollectionItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
    }
    private func refreshItem(_ itemID: UUID) {
        guard let repository, let collectionID = selectedCollection?.id,
              let refreshed = repository.item(id: itemID, in: collectionID) else { return }
        replaceItem(refreshed)
    }
    private func dateSorts(_ lhs: CollectionItem, before rhs: CollectionItem, ascending: Bool) -> Bool {
        switch (lhs.earliestDateTag, rhs.earliestDateTag) {
        case (nil, nil): return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return ascending ? left < right : left > right
        }
    }
    private func metadataSorts(_ lhs: CollectionItem, before rhs: CollectionItem, field: MetadataFieldDefinition, direction: SortDirection) -> Bool {
        let left = lhs.metadata[field.storageKey]
        let right = rhs.metadata[field.storageKey]
        switch field.type {
        case .text:
            return textValuesSort(metadataText(left), metadataText(right), lhs: lhs, rhs: rhs, direction: direction)
        case .number:
            return valuesSort(metadataNumber(left), metadataNumber(right), lhs: lhs, rhs: rhs, direction: direction)
        case .date:
            return valuesSort(metadataDate(left), metadataDate(right), lhs: lhs, rhs: rhs, direction: direction)
        case .boolean:
            return valuesSort(metadataBoolean(left), metadataBoolean(right), lhs: lhs, rhs: rhs, direction: direction)
        case .color:
            return textValuesSort(metadataText(left), metadataText(right), lhs: lhs, rhs: rhs, direction: direction)
        }
    }
    private func valuesSort<Value: Comparable>(_ left: Value?, _ right: Value?, lhs: CollectionItem, rhs: CollectionItem, direction: SortDirection) -> Bool {
        switch (left, right) {
        case (nil, nil): return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?):
            if left == right { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
            return direction == .ascending ? left < right : left > right
        }
    }
    private func textValuesSort(_ left: String?, _ right: String?, lhs: CollectionItem, rhs: CollectionItem, direction: SortDirection) -> Bool {
        switch (left, right) {
        case (nil, nil): return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?):
            let comparison = left.localizedStandardCompare(right)
            if comparison == .orderedSame { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
            return direction == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
    private func metadataText(_ value: MetadataValue?) -> String? {
        guard let value else { return nil }
        let text = value.displayValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    private func metadataNumber(_ value: MetadataValue?) -> Double? {
        switch value {
        case .integer(let number): return Double(number)
        case .decimal(let number): return number
        case .string(let text): return Self.metadataNumberFormatter.number(from: text)?.doubleValue
        default: return nil
        }
    }
    private func metadataDate(_ value: MetadataValue?) -> Date? {
        if case .date(let date)? = value { return date }
        return nil
    }
    private func metadataBoolean(_ value: MetadataValue?) -> Int? {
        switch value {
        case .boolean(let boolean): return boolean ? 1 : 0
        case .integer(let number): return number == 0 ? 0 : 1
        case .decimal(let number): return number == 0 ? 0 : 1
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y", "1", "on": return 1
            case "false", "no", "n", "0", "off": return 0
            default: return nil
            }
        default: return nil
        }
    }
    private static let metadataNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        return formatter
    }()
    private static func normalizedText(_ value: String) -> String { value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func words(_ value: String) -> Set<String> { Set(normalizedText(value).split(separator: " ").map(String.init)) }
}
