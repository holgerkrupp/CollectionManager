import Foundation
import Observation
import SwiftData

@MainActor @Observable final class AppStore {
    private var repository: CollectionRepository?
    private var modelContext: ModelContext?
    var collections: [CollectionModel] = []; var selectedCollection: CollectionModel?; var items: [CollectionItem] = []; var webSyncs: [WebSyncRecord] = []; var searchText = ""; var selectedState: ItemState?; var selectedBrand: String?; var itemSort: ItemSort = .updatedDescending; var isLoading = false; var lastWebSyncMessage: String?; var syncState: CollectionSyncState = .idle; var syncError: String?; var pendingSyncCount = 0
    func configure(context: ModelContext) { guard repository == nil else { return }; modelContext = context; repository = CollectionRepository(context: context) }
    func load() { guard let repository else { return }; isLoading = true; collections = repository.collections(); selectedCollection = selectedCollection.flatMap { selected in collections.first(where: { $0.id == selected.id }) } ?? collections.first; items = selectedCollection.map { repository.items(in: $0.id) } ?? []; webSyncs = selectedCollection.map { repository.webSyncs(for: $0.id) } ?? []; isLoading = false }
    func select(_ collectionID: UUID?) { guard let collectionID, let collection = collections.first(where: { $0.id == collectionID }) else { return }; selectedCollection = collection; selectedState = nil; selectedBrand = nil; load() }
    func addCollection(name: String, icon: String, subtitle: String, category: CollectionCategory = .custom) { repository?.addCollection(name: name, icon: icon, subtitle: subtitle, category: category); load() }
    func updateCollection(_ collection: CollectionModel) { repository?.updateCollection(collection); load() }
    func deleteCollection(_ collection: CollectionModel) { guard collection.role.canDelete else { return }; if selectedCollection?.id == collection.id { selectedCollection = nil }; repository?.deleteCollection(collection); load() }
    func addItem(title: String, brand: String, variant: String, description: String, state: ItemState, quantity: Int, tags: [String], metadata: [String: MetadataValue] = [:], barcode: Barcode? = nil, imageData: Data? = nil, sourceIdentifier: String? = nil) { guard let collectionID = selectedCollection?.id else { return }; let item = CollectionItem(id: UUID(), collectionID: collectionID, title: title, brand: brand, variant: variant, itemDescription: description, state: state, quantity: quantity, barcode: barcode, createdAt: .now, updatedAt: .now, consumedAt: state == .consumed ? .now : nil, tags: tags, metadata: metadata, imageSystemName: "shippingbox.fill", imageData: imageData, importSourceKey: sourceIdentifier); repository?.addItem(item); load() }
    func importDrafts(_ drafts: [ImportDraft]) { guard let repository, let collectionID = selectedCollection?.id else { return }; let entries = drafts.map { draft in (draft: draft, sourceKey: draft.sourceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? draft.sourceIdentifier!.trimmingCharacters(in: .whitespacesAndNewlines) : "\(draft.title)|\(draft.brand)|\(draft.variant)") }; repository.importDrafts(entries, collectionID: collectionID); load() }
    func deduplicateImportedItems() -> Int { guard let repository, let collectionID = selectedCollection?.id else { return 0 }; let removed = repository.deduplicateItems(in: collectionID); load(); return removed }
    func deleteAllImportedItems() -> Int { guard let repository, let collectionID = selectedCollection?.id else { return 0 }; let removed = repository.deleteAllImportedItems(in: collectionID); load(); return removed }
    func applyTagRules(_ options: TagGenerationOptions) -> Int { guard let repository, let collectionID = selectedCollection?.id else { return 0 }; let changed = repository.applyTagRules(options, in: collectionID); load(); return changed }
    func applyMergedTagsToExistingItems() -> Int { guard let repository, let collectionID = selectedCollection?.id else { return 0 }; let changed = repository.applyMergedTags(in: collectionID); load(); return changed }
    func updateItem(_ item: CollectionItem, previousState: ItemState) { repository?.updateItem(item, previousState: previousState); load() }
    func setRating(_ value: Int?, for item: CollectionItem) { repository?.setRating(for: item, value: value, participant: .current); load() }
    @discardableResult func addComment(_ text: String, to item: CollectionItem) -> ItemComment? { let comment = repository?.addComment(to: item, text: text, participant: .current); load(); return comment }
    func deleteItem(_ item: CollectionItem) { repository?.deleteItem(item); load() }
    func deleteAllItems() -> Int { guard let repository, let collectionID = selectedCollection?.id else { return 0 }; let removed = repository.deleteAllItems(in: collectionID); load(); return removed }
    func saveWebSync(_ sync: WebSyncRecord) { repository?.addWebSync(sync); UserDefaults.standard.set(Double(sync.intervalMinutes), forKey: "websync.minimumIntervalMinutes"); load(); WebSyncScheduler.schedule() }
    func updateWebSync(_ sync: WebSyncRecord) { repository?.updateWebSync(sync); UserDefaults.standard.set(Double(sync.intervalMinutes), forKey: "websync.minimumIntervalMinutes"); load(); WebSyncScheduler.schedule() }
    func deleteWebSync(_ sync: WebSyncRecord) { repository?.deleteWebSync(sync); load(); WebSyncScheduler.schedule() }
    func syncWebSource(_ sync: WebSyncRecord) async { guard let modelContext else { return }; let result = await HTMLSyncCoordinator(context: modelContext).sync(sync); lastWebSyncMessage = result.error ?? "Sync complete: \(result.added) added, \(result.updated) updated"; load() }
    func syncCollections() async {
        guard let repository else { return }
        syncState = .syncing; syncError = nil
        let service = CloudKitSharingService()
        let localCollections = repository.collections(); let localItems = localCollections.flatMap { repository.items(in: $0.id) }; let localEvents = localCollections.flatMap { repository.events(in: $0.id) }; let mutations = repository.pendingMutations()
        do {
            let snapshots = try await service.sync(collections: localCollections, items: localItems, events: localEvents, mutations: mutations)
            repository.merge(snapshots)
            for mutation in mutations { repository.removeMutation(mutation) }
            repository.setSyncState(collectionID: selectedCollection?.id ?? localCollections.first?.id ?? UUID(), state: .idle, lastSyncedAt: .now)
            syncState = .idle; pendingSyncCount = 0; load()
        } catch {
            syncState = .error; syncError = error.localizedDescription
            for mutation in mutations { repository.markMutation(mutation, error: error) }
            pendingSyncCount = repository.pendingMutations().count
            if let collectionID = selectedCollection?.id { repository.setSyncState(collectionID: collectionID, state: .error, error: error.localizedDescription) }
        }
    }
    func acceptShare(from url: URL) async { do { try await CloudKitSharingService().acceptShare(from: url); await syncCollections() } catch { syncState = .error; syncError = error.localizedDescription } }
    var statuses: [CollectionStatus] {
        guard let configured = selectedCollection?.statuses, !configured.isEmpty else { return CollectionStatus.defaults }
        return configured
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
    var brands: [String] { Array(Set(items.map(\.brand).filter { !$0.isEmpty })).sorted() }
    var visibleItems: [CollectionItem] {
        let filtered = items.filter { item in
            let q = searchText.lowercased()
            let haystack = ([item.title, item.brand, item.variant, item.itemDescription, item.barcode?.value ?? ""] + item.tags + item.metadata.values.map(\.displayValue)).joined(separator: " ").lowercased()
            return (q.isEmpty || haystack.contains(q)) && (selectedState == nil || item.state == selectedState) && (selectedBrand == nil || item.brand == selectedBrand)
        }
        switch itemSort {
        case .updatedDescending: return filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .titleAscending: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .dateAscending: return filtered.sorted { dateSorts($0, before: $1, ascending: true) }
        case .dateDescending: return filtered.sorted { dateSorts($0, before: $1, ascending: false) }
        }
    }
    var hasDateTags: Bool { items.contains { !$0.dateTags.isEmpty } }
    private func dateSorts(_ lhs: CollectionItem, before rhs: CollectionItem, ascending: Bool) -> Bool {
        switch (lhs.earliestDateTag, rhs.earliestDateTag) {
        case (nil, nil): return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return ascending ? left < right : left > right
        }
    }
    var stats: (stored: Int, consumed: Int, wanted: Int) { (items.filter { $0.state == .stored }.count, items.filter { $0.state == .consumed }.count, items.filter { $0.state == .wanted }.count) }
    private static func normalizedText(_ value: String) -> String { value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func words(_ value: String) -> Set<String> { Set(normalizedText(value).split(separator: " ").map(String.init)) }
}
