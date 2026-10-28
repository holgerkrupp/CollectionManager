import Foundation
import CloudKit
import Observation
import SwiftData

@MainActor @Observable final class AppStore {
    private var repository: CollectionRepository?
    private var backgroundRepository: CollectionBackgroundRepository?
    private var modelContext: ModelContext?
    private var cloudService: CloudKitSharingService?
    private var recoveryContainer: ModelContainer?
    var cloudPausedForOneTimeRecovery = false
    private var recoveryPauseMessage: String { String(localized: "Your older library has been restored locally. iCloud sync is paused until the one-time recovery is reviewed.") }
    private var localChangesObservation: NSObjectProtocol?
    var sharingSession: CollectionSharingSession?
    let editSessions = CollectionEditSessions()
    var collections: [CollectionModel] = []
    var selectedCollection: CollectionModel?
    var items: [CollectionItem] = [] { didSet { rebuildDerivedItemState() } }
    var webSyncs: [WebSyncRecord] = []
    var searchText = "" { didSet { rebuildVisibleItems() } }
    var selectedState: ItemState? { didSet { rebuildVisibleItems() } }
    var selectedBrand: String? { didSet { rebuildVisibleItems() } }
    var itemSort: ItemSort = .updatedDescending { didSet { rebuildVisibleItems() } }
    private var searchIndex = ItemSearchIndex()
    private var derivedTask: Task<ItemDerivedState, Error>?
    private var derivedGeneration: UInt64 = 0
    private var queryTask: Task<[CollectionItem], Error>?
    private var queryGeneration: UInt64 = 0
    private(set) var visibleItems: [CollectionItem] = [] { didSet { visibleItemsRevision &+= 1 } }
    private(set) var visibleItemsRevision: UInt64 = 0
    private(set) var brands: [String] = []
    private(set) var hasDateTags = false
    private(set) var stats: (stored: Int, consumed: Int, wanted: Int) = (0, 0, 0)
    private(set) var pendingItemOperations: Set<UUID> = []
    private(set) var isBulkOperationInProgress = false
    /// Set when a delete could not be applied, so the UI can explain it
    /// instead of leaving the row silently in place.
    var itemActionError: String?
    /// A persistence failure is distinct from an empty collection and remains
    /// visible until the user acknowledges it.
    var persistenceError: String?
    /// An item an App Intent asked to bring on screen. The collection detail
    /// view presents it and clears it when the sheet closes.
    var openedItem: CollectionItem?
    var isLoading = false
    var lastWebSyncMessage: String?
    var syncState: CollectionSyncState = .idle
    var syncError: String?
    var pendingSyncCount = 0
    var legacyReviewCount = 0
    private var syncRequestedWhileSyncing = false
    func configure(context: ModelContext, container: ModelContainer, failureInjector: ((RepositoryFailurePoint) throws -> Void)? = nil) {
        guard repository == nil else { return }
        modelContext = context
        recoveryContainer = container
        do { cloudPausedForOneTimeRecovery = try LegacyStoreRecovery.cloudIsPaused(in: container) }
        catch { cloudPausedForOneTimeRecovery = true; persistenceError = error.localizedDescription }
        let repository = CollectionRepository(context: context)
        repository.failureInjector = failureInjector
        self.repository = repository
        backgroundRepository = CollectionBackgroundRepository(container: container)
        if CloudKitSharingService.isAvailable {
            cloudService = CloudKitSharingService(modelContainer: container)
            localChangesObservation = NotificationCenter.default.addObserver(forName: .collectionManagerLocalChanges, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.syncCollections() }
            }
        }
    }

    func restoreOldDefaultStoreOnce() async throws -> LegacyStoreRecoverySummary {
        guard PersistentStoreBootstrap.libraryEnvironment == .production else { throw RepositoryError.validation(String(localized: "Run the Production scheme to recover this older library.")) }
        guard let recoveryContainer else { throw RepositoryError.fetchFailed }
        cloudPausedForOneTimeRecovery = true
        let result = try await LegacyStoreRecovery(target: recoveryContainer).restore()
        load()
        return result
    }
    func resumeCloudAfterOneTimeRecovery() async throws {
        guard let recoveryContainer else { throw RepositoryError.fetchFailed }
        try await LegacyStoreRecovery(target: recoveryContainer).resumeCloudAfterReview()
        cloudPausedForOneTimeRecovery = false
    }
    func beginIntentOperation() throws {
        guard repository != nil else { throw RepositoryError.validation(String(localized: "Your library is unavailable. Open Collection Manager to recover the persistent store.")) }
        persistenceError = nil
        itemActionError = nil
    }

    func checkIntentOperation() throws {
        if let failure = persistenceError ?? itemActionError { throw RepositoryError.validation(failure) }
    }
    func load() { loadCollections(); loadSelectedCollection() }
    func loadCollections() {
        do {
            guard let repository else { return }
            isLoading = true
            defer { isLoading = false }
            collections = try repository.collections()
            LocalNotificationPreferences.migrateLegacySettings(to: collections.map(\.id))
            selectedCollection = selectedCollection.flatMap { selected in collections.first(where: { $0.id == selected.id }) } ?? collections.first
            if case .metadata(let fieldID, _) = itemSort,
               selectedCollection?.metadataFields.contains(where: { $0.id == fieldID }) != true {
                itemSort = .updatedDescending
            }
            isLoading = false

        } catch { persistenceError = error.localizedDescription }
    }
    func loadSelectedCollection() {
        do {
            guard let repository, let collectionID = selectedCollection?.id else { items = []; webSyncs = []; return }
            isLoading = true
            defer { isLoading = false }
            items = try repository.items(in: collectionID)
            webSyncs = try repository.webSyncs(for: collectionID)
            isLoading = false

        } catch { persistenceError = error.localizedDescription }
    }
    func loadSelectedCollectionInBackground() async {
        do {
            guard let repository, let backgroundRepository, let collectionID = selectedCollection?.id else { items = []; webSyncs = []; return }
            isLoading = true
            defer { isLoading = false }
            let loadedItems = try await backgroundRepository.items(in: collectionID)
            guard selectedCollection?.id == collectionID else { return }
            if items != loadedItems { items = loadedItems }
            webSyncs = try repository.webSyncs(for: collectionID)
            isLoading = false

        } catch { persistenceError = error.localizedDescription }
    }
    func select(_ collectionID: UUID?) { guard let collectionID, let collection = collections.first(where: { $0.id == collectionID }), selectedCollection?.id != collectionID else { return }; selectedCollection = collection; items = []; webSyncs = []; selectedState = nil; selectedBrand = nil; itemSort = .updatedDescending; Task { await loadSelectedCollectionInBackground() } }
    @discardableResult func addCollection(name: String, icon: String, subtitle: String, category: CollectionCategory = .custom) -> Bool {
        do { guard let repository else { return false }; try repository.addCollection(name: name, icon: icon, subtitle: subtitle, category: category); loadCollections(); loadSelectedCollection(); return true
        } catch { persistenceError = error.localizedDescription; return false }
    }
    @discardableResult func updateCollection(_ collection: CollectionModel) -> Bool {
        do { guard let repository else { return false }; try repository.updateCollection(collection); loadCollections(); loadSelectedCollection(); return true
        } catch { persistenceError = error.localizedDescription; return false }
    }
    @discardableResult func addMetadataFields(_ fields: [MetadataFieldDefinition]) -> Bool {
        guard !fields.isEmpty else { return true }
        guard var collection = selectedCollection, collection.role.canEdit else { return false }
        let existingIDs = Set(collection.metadataFields.map(\.id))
        collection.metadataFields.append(contentsOf: fields.filter { !existingIDs.contains($0.id) })
        return updateCollection(collection)
    }
    func deleteCollection(_ collection: CollectionModel) async {
        do {
            guard collection.role.canDelete, let backgroundRepository else { return }
            let previousCollections = collections
            collections.removeAll { $0.id == collection.id }
            if selectedCollection?.id == collection.id {
                selectedCollection = collections.first
                items = []
                webSyncs = []
            }
            await Task.yield()
            if try await backgroundRepository.deleteCollection(id: collection.id) {
                if selectedCollection != nil { await loadSelectedCollectionInBackground() }
            } else {
                collections = previousCollections
                selectedCollection = collections.first(where: { $0.id == collection.id }) ?? collections.first
                await loadSelectedCollectionInBackground()
            }

        } catch { persistenceError = error.localizedDescription; loadCollections(); loadSelectedCollection() }
    }
    /// Adds to `collectionID`, or to the selected collection when it is nil.
    /// Returns nil when the item was rejected as a duplicate or not editable.
    @discardableResult func addItem(title: String, brand: String, variant: String, description: String, state: ItemState, quantity: Int, tags: [String], metadata: [String: MetadataValue] = [:], barcode: Barcode? = nil, imageData: Data? = nil, sourceIdentifier: String? = nil, sourceSnapshot: ProductSourceSnapshot? = nil, allowsDuplicates: Bool = false, collectionID: UUID? = nil) -> CollectionItem? {
        do {
            guard let collectionID = collectionID ?? selectedCollection?.id else { return nil }
            if let collection = collections.first(where: { $0.id == collectionID }), collection.barcodeRequired, barcode == nil {
                itemActionError = String(localized: "A barcode is required for this collection. Add a valid barcode before saving the item.")
                return nil
            }
            let item = CollectionItem(id: UUID(), collectionID: collectionID, title: title, brand: brand, variant: variant, itemDescription: description, state: state, quantity: quantity, barcode: barcode, createdAt: .now, updatedAt: .now, consumedAt: state == .consumed ? .now : nil, tags: tags, metadata: metadata, imageSystemName: "shippingbox.fill", imageData: imageData, importSourceKey: sourceIdentifier, sourceSnapshot: sourceSnapshot)
            guard try repository?.addItem(item, allowsDuplicates: allowsDuplicates) == true else { reportPersistenceFailure(); return nil }
            let saved = try repository?.item(id: item.id) ?? item
            if collectionID == selectedCollection?.id { items.insert(saved, at: 0) }
            indexInSpotlight([saved])
            Task { await syncCollections() }
            return saved

        } catch { persistenceError = error.localizedDescription; return nil }
    }
    @discardableResult func bulkUpdateState(for filteredItems: [CollectionItem], to state: ItemState) -> Int? {
        do {
            guard let repository, let collection = selectedCollection, collection.role.canEdit else { return nil }
            guard !filteredItems.isEmpty else { return 0 }
            guard filteredItems.allSatisfy({ $0.collectionID == collection.id }) else { return nil }
            let changed = try repository.bulkUpdateState(for: Set(filteredItems.map(\.id)), in: collection.id, to: state)
            if changed > 0 { loadSelectedCollection() }
            return changed

        } catch { persistenceError = error.localizedDescription; return nil }
    }
    @discardableResult func importDrafts(_ drafts: [ImportDraft], collectionID: UUID? = nil, metadataFieldsToCreate: [MetadataFieldDefinition] = []) async -> Bool {
        guard let backgroundRepository, let collectionID = collectionID ?? selectedCollection?.id else { return false }
        let entries = drafts.map { draft in
            (draft: draft, sourceKey: draft.sourceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? draft.sourceIdentifier!.trimmingCharacters(in: .whitespacesAndNewlines) : "\(draft.title)|\(draft.brand)|\(draft.variant)")
        }
        do {
            // The repository knows whether a matched item already has a barcode;
            // filtering missing source values here would wrongly skip updates.
            try await backgroundRepository.importDrafts(entries, collectionID: collectionID, metadataFieldsToCreate: metadataFieldsToCreate)
            loadCollections()
            if selectedCollection?.id == collectionID { await loadSelectedCollectionInBackground() }
            return true
        } catch { persistenceError = error.localizedDescription; return false }
    }
    @discardableResult func importNewDrafts(_ drafts: [ImportDraft], allowsDuplicates: Bool, collectionID: UUID? = nil, metadataFieldsToCreate: [MetadataFieldDefinition] = []) async -> Bool {
        guard let backgroundRepository, let collectionID = collectionID ?? selectedCollection?.id else { return false }
        do {
            try await backgroundRepository.importNewDrafts(drafts, collectionID: collectionID, allowsDuplicates: allowsDuplicates, metadataFieldsToCreate: metadataFieldsToCreate)
            loadCollections()
            if selectedCollection?.id == collectionID { await loadSelectedCollectionInBackground() }
            return true
        } catch { persistenceError = error.localizedDescription; return false }
    }
    func deduplicateItems() -> Int? {
        do {
            guard let repository, let collectionID = selectedCollection?.id else { return nil }
            let removed = try repository.deduplicateItems(in: collectionID)
            loadSelectedCollection()
            if removed > 0 { Task { await syncCollections() } }
            return removed

        } catch { persistenceError = error.localizedDescription; return nil }
    }
    func deduplicateImportedItems() -> Int? { deduplicateItems() }
    func deleteAllImportedItems() -> Int? {
        do { guard let repository, let collectionID = selectedCollection?.id else { return nil }; let removed = try repository.deleteAllImportedItems(in: collectionID); loadSelectedCollection(); return removed
        } catch { persistenceError = error.localizedDescription; return nil }
    }
    func applyTagRules(_ options: TagGenerationOptions) -> Int? {
        do { guard let repository, let collectionID = selectedCollection?.id else { return nil }; let changed = try repository.applyTagRules(options, in: collectionID); loadSelectedCollection(); return changed
        } catch { persistenceError = error.localizedDescription; return nil }
    }
    func applyMergedTagsToExistingItems() -> Int? {
        do { guard let repository, let collectionID = selectedCollection?.id else { return nil }; let changed = try repository.applyMergedTags(in: collectionID); loadSelectedCollection(); return changed
        } catch { persistenceError = error.localizedDescription; return nil }
    }
    @discardableResult func updateItem(_ item: CollectionItem, previousState: ItemState) -> Bool {
        do {
            if let collection = collections.first(where: { $0.id == item.collectionID }), collection.barcodeRequired, item.barcode == nil {
                itemActionError = String(localized: "A barcode is required for this collection. Add a valid barcode before saving the item.")
                return false
            }
            guard let repository else { return false }; try repository.updateItem(item, previousState: previousState)
            guard let saved = try repository.item(id: item.id) else { throw RepositoryError.fetchFailed }
            replaceItem(saved); indexInSpotlight([saved]); return true

        } catch { persistenceError = error.localizedDescription; return false }
    }
    @discardableResult func setRating(_ value: Int?, for item: CollectionItem) -> Bool {
        guard let repository else { return false }
        do {
            try repository.setRating(for: item, value: value, participant: .current)
            refreshItem(item.id)
            return true
        } catch { persistenceError = error.localizedDescription; return false }
    }
    @discardableResult func addComment(_ text: String, to item: CollectionItem) -> ItemComment? {
        do { let comment = try repository?.addComment(to: item, text: text, participant: .current); refreshItem(item.id); return comment
        } catch { persistenceError = error.localizedDescription; return nil }
    }
    @discardableResult func deleteItem(_ item: CollectionItem) async -> Bool {
        do {
            guard !pendingItemOperations.contains(item.id) else { return false }
            pendingItemOperations.insert(item.id)
            defer { pendingItemOperations.remove(item.id) }
            let previousIndex = items.firstIndex { $0.id == item.id }
            items.removeAll { $0.id == item.id }
            // Let SwiftUI commit the optimistic removal/progress state before the
            // local SwiftData transaction starts.
            await Task.yield()
            let succeeded = try await backgroundRepository?.deleteItem(id: item.id, collectionID: item.collectionID) ?? false
            if succeeded {
                removeFromSpotlight(itemIDs: [item.id])
                // Push the tombstone while the app is in the foreground instead of
                // waiting for the next periodic sync.
                Task { await syncCollections() }
            } else {
                // Put the row back where it was and say so. A silent failure that
                // looked like a successful delete until the next refresh was the
                // main reason deleting felt unreliable.
                items.insert(item, at: min(previousIndex ?? items.count, items.count))
                itemActionError = String(localized: "“\(item.title)” could not be deleted. Only an owner or an editor of this collection can remove items.")
            }
            pendingItemOperations.remove(item.id)
            return succeeded

        } catch { persistenceError = error.localizedDescription; loadSelectedCollection(); return false }
    }
    func deleteAllItems() async -> Int? {
        do {
            guard let repository, let collectionID = selectedCollection?.id, !isBulkOperationInProgress else { return nil }
            isBulkOperationInProgress = true
            defer { isBulkOperationInProgress = false }
            let previousItems = items
            items = []
            await Task.yield()
            let removed = try await backgroundRepository?.deleteAllItems(in: collectionID) ?? repository.deleteAllItems(in: collectionID)
            if removed == 0, !previousItems.isEmpty {
                loadSelectedCollection()
                itemActionError = String(localized: "The items could not be deleted. Only an owner or an editor of this collection can remove items.")
            }
            isBulkOperationInProgress = false
            if removed > 0 { Task { await syncCollections() } }
            return removed

        } catch { persistenceError = error.localizedDescription; loadSelectedCollection(); return nil }
    }
    @discardableResult func saveWebSync(_ sync: WebSyncRecord, metadataFieldsToCreate: [MetadataFieldDefinition] = []) -> Bool {
        do { guard let repository else { return false }; try repository.addWebSync(sync, metadataFieldsToCreate: metadataFieldsToCreate); loadCollections(); if let id = selectedCollection?.id { webSyncs = try repository.webSyncs(for: id) }; scheduleWebSync(); return true
        } catch { persistenceError = error.localizedDescription; return false }
    }
    @discardableResult func updateWebSync(_ sync: WebSyncRecord, metadataFieldsToCreate: [MetadataFieldDefinition] = [], update: (WebSyncRecord) throws -> Void) -> Bool {
        do { guard let repository else { return false }; try repository.updateWebSync(sync, metadataFieldsToCreate: metadataFieldsToCreate, update: update); loadCollections(); if let id = selectedCollection?.id { webSyncs = try repository.webSyncs(for: id) }; scheduleWebSync(); return true
        } catch { persistenceError = error.localizedDescription; return false }
    }
    func deleteWebSync(_ sync: WebSyncRecord) {
        do { try repository?.deleteWebSync(sync); if let id = selectedCollection?.id { webSyncs = try repository?.webSyncs(for: id) ?? [] }; scheduleWebSync()
        } catch { persistenceError = error.localizedDescription }
    }
    func syncWebSource(_ sync: WebSyncRecord) async { guard !cloudPausedForOneTimeRecovery else { lastWebSyncMessage = recoveryPauseMessage; return }; guard let modelContext else { return }; let result = await HTMLSyncCoordinator(context: modelContext).sync(sync); lastWebSyncMessage = result.error ?? String(localized: "Sync complete. Added: \(result.added). Updated: \(result.updated)."); scheduleWebSync(); await loadSelectedCollectionInBackground() }

    private func scheduleWebSync() {
        guard let modelContext else { return }
        WebSyncScheduler.schedule(context: modelContext)
    }
    func syncCollections() async {
        guard !cloudPausedForOneTimeRecovery else { syncState = .error; syncError = recoveryPauseMessage; return }
        guard let repository, let cloudService else { return }
        guard syncState != .syncing else { syncRequestedWhileSyncing = true; return }
        syncState = .syncing
        syncError = nil
        do {
            try await cloudService.synchronize()
            sharingSession = cloudService.sharingSession
            legacyReviewCount = cloudService.legacyReviewCount
            if cloudService.needsContinuation { syncRequestedWhileSyncing = true }
            pendingSyncCount = try repository.pendingMutations().count
            syncState = .idle
            loadCollections()
            await loadSelectedCollectionInBackground()
        } catch {
            syncState = .error
            sharingSession = cloudService.sharingSession
            legacyReviewCount = cloudService.legacyReviewCount
            syncError = CollectionSharingSession.message(for: error)
            do { pendingSyncCount = try repository.pendingMutations().count }
            catch { persistenceError = error.localizedDescription }
            // Already committed imports/permission changes remain usable even
            // when a different zone or legacy review prevents full completion.
            loadCollections()
            await loadSelectedCollectionInBackground()
        }
        if syncRequestedWhileSyncing {
            syncRequestedWhileSyncing = false
            // One coalesced follow-up, scheduled outside the current stack.
            Task { await self.syncCollections() }
        }
    }

    @discardableResult func acceptShare(from url: URL) async -> Bool {
        guard !cloudPausedForOneTimeRecovery else { syncError = recoveryPauseMessage; return false }
        guard let cloudService else { syncError = SharingError.unavailable.localizedDescription; return false }
        do {
            try await cloudService.accept(url: url)
            sharingSession = cloudService.sharingSession
            await syncCollections()
            return true
        } catch { syncState = .error; syncError = CollectionSharingSession.message(for: error); return false }
    }

    @discardableResult func acceptShare(metadata: CKShare.Metadata) async -> Bool {
        guard !cloudPausedForOneTimeRecovery else { syncError = recoveryPauseMessage; return false }
        guard let cloudService else { syncError = SharingError.unavailable.localizedDescription; return false }
        do {
            try await cloudService.accept(metadata)
            sharingSession = cloudService.sharingSession
            await syncCollections()
            return true
        } catch { syncState = .error; syncError = CollectionSharingSession.message(for: error); return false }
    }
    func legacyCandidates(limit: Int = 50, offset: Int = 0) async throws -> [CollectionLegacyCandidate] {
        guard let cloudService else { throw SharingError.unavailable }
        return try await cloudService.legacyCandidates(limit: limit, offset: offset)
    }

    func authorizeLegacyUpload(_ id: UUID) async throws {
        guard let cloudService else { throw SharingError.unavailable }
        try await cloudService.authorizeLegacyUpload(id)
        await syncCollections()
    }

    // MARK: App Intents support

    /// Collections for App Intents, which can run before any window has
    /// appeared and loaded them.
    func intentCollections() -> [CollectionModel] {
        if collections.isEmpty { loadCollections() }
        return collections
    }
    /// Items across every collection, not only the one on screen.
    func intentItems() -> [CollectionItem] {
        do {
            guard let repository else { return [] }
            return try intentCollections().flatMap { try repository.items(in: $0.id) }

        } catch { persistenceError = error.localizedDescription; return [] }
    }
    func item(id: UUID) -> CollectionItem? {
        do { return try repository?.item(id: id)
        } catch { persistenceError = error.localizedDescription; return nil }
    }
    /// Moves items in any collection to `state`, skipping collections that
    /// cannot be edited or do not define that status. Returns the changed
    /// items as they were before, so the change can be undone.
    @discardableResult func setState(_ state: ItemState, forItemIDs itemIDs: some Sequence<UUID>) -> [CollectionItem] {
        do {
            guard let repository else { return [] }
            let collectionsByID = Dictionary(uniqueKeysWithValues: intentCollections().map { ($0.id, $0) })
            let targets = try Set(itemIDs).compactMap { try repository.item(id: $0) }.filter { $0.state != state }
            var changed: [CollectionItem] = []
            for (collectionID, group) in Dictionary(grouping: targets, by: \.collectionID) {
                guard let collection = collectionsByID[collectionID], collection.role.canEdit,
                      collection.statuses.contains(where: { $0.id == state.rawValue }) else { continue }
                if try repository.bulkUpdateState(for: Set(group.map(\.id)), in: collectionID, to: state) > 0 { changed += group }
            }
            guard !changed.isEmpty else { return [] }
            loadSelectedCollection()
            indexInSpotlight(try changed.compactMap { try repository.item(id: $0.id) })
            Task { await syncCollections() }
            return changed

        } catch { persistenceError = error.localizedDescription; return [] }
    }
    /// Puts items back to the statuses captured in `snapshot`.
    func restoreStates(_ snapshot: [CollectionItem]) {
        for (state, group) in Dictionary(grouping: snapshot, by: \.state) { setState(state, forItemIDs: group.map(\.id)) }
    }
    func open(collectionID: UUID) {
        guard intentCollections().contains(where: { $0.id == collectionID }) else { return }
        select(collectionID)
    }
    func open(itemID: UUID) {
        guard let item = item(id: itemID) else { return }
        open(collectionID: item.collectionID)
        openedItem = item
    }

    var statuses: [CollectionStatus] {
        guard let configured = selectedCollection?.statuses, !configured.isEmpty else { return CollectionStatus.defaults }
        return configured
    }
    var itemSortLabel: String {
        guard case .metadata(let fieldID, let direction) = itemSort else { return itemSort.label }
        guard let field = selectedCollection?.metadataFields.first(where: { $0.id == fieldID }) else { return ItemSort.updatedDescending.label }
        return String(localized: "\(field.name) (\(direction.label.lowercased()))")
    }
    func status(for state: ItemState, in collection: CollectionModel? = nil) -> CollectionStatus { (collection ?? selectedCollection)?.status(for: state) ?? CollectionStatus.fallback(for: state) }
    func barcodeStatus(_ barcode: Barcode) -> ItemState? { items.first(where: { $0.barcode == barcode })?.state }
    func productMatches(for barcode: Barcode, productName: String? = nil) -> [CollectionProductMatch] {
        do {
            guard let repository else { return [] }
            let collectionNames = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.name) })
            let normalizedName = productName.map(Self.normalizedText)
            let nameWords = normalizedName.map(Self.words) ?? []
            return try collections.flatMap { collection in
                try repository.items(in: collection.id).compactMap { item in
                    var matchedBy: [String] = []
                    if item.barcode == barcode { matchedBy.append(String(localized: "Barcode")) }
                    if let normalizedName, !normalizedName.isEmpty {
                        let itemWords = Self.words(item.title)
                        if Self.normalizedText(item.title) == normalizedName || nameWords.isSubset(of: itemWords) {
                            matchedBy.append(String(localized: "Name"))
                        }
                        let normalizedTags = item.tags.map(Self.normalizedText)
                        let tagWords = Set(normalizedTags.flatMap(Self.words))
                        if normalizedTags.contains(normalizedName) || nameWords.isSubset(of: tagWords) {
                            matchedBy.append(String(localized: "Tags"))
                        }
                    }
                    guard !matchedBy.isEmpty else { return nil }
                    return CollectionProductMatch(id: item.id, collectionName: collectionNames[item.collectionID] ?? collection.name, itemTitle: item.title, state: item.state, status: collection.status(for: item.state), matchedBy: matchedBy)
                }
            }

        } catch { persistenceError = error.localizedDescription; return [] }
    }
    func refreshLocale() { rebuildDerivedItemState() }

    private func rebuildDerivedItemState() {
        derivedTask?.cancel()
        derivedGeneration &+= 1
        let generation = derivedGeneration
        let snapshot = items
        let locale = Locale.current
        if let collectionID = snapshot.first?.collectionID, visibleItems.first?.collectionID != collectionID {
            visibleItems = []; brands = []; hasDateTags = false; stats = (0, 0, 0)
        }
        if snapshot.isEmpty {
            derivedTask = nil
            searchIndex = ItemSearchIndex()
            brands = []; hasDateTags = false; stats = (0, 0, 0)
            visibleItems = []
            rebuildVisibleItems()
            return
        }
        let worker = Task.detached(priority: .userInitiated) {
            try ItemDerivedState.prepare(items: snapshot, locale: locale)
        }
        derivedTask = worker
        Task { [weak self] in
            do {
                let result = try await worker.value
                guard let self, self.derivedGeneration == generation else { return }
                self.searchIndex = result.searchIndex
                self.brands = result.brands
                self.hasDateTags = result.hasDateTags
                self.stats = result.stats
            } catch { /* A newer item/locale generation owns preparation. */ }
        }
        rebuildVisibleItems()
    }

    private func reportPersistenceFailure() {
        persistenceError = repository?.lastPersistenceError?.localizedDescription
    }
    private func rebuildVisibleItems() {
        queryTask?.cancel()
        queryGeneration &+= 1
        let generation = queryGeneration
        let snapshot = items
        let prepared = derivedTask
        let priorIndex = searchIndex
        let text = searchText, state = selectedState, brand = selectedBrand, sort = itemSort
        let fields = selectedCollection?.metadataFields ?? []
        let locale = Locale.current
        let worker = Task.detached(priority: .userInitiated) {
            let index = try await prepared?.value.searchIndex ?? priorIndex
            try Task.checkCancellation()
            let request = ItemQueryRequest(items: snapshot, searchIndex: index,
                searchText: text, selectedState: state, selectedBrand: brand,
                sort: sort, metadataFields: fields, locale: locale)
            return try ItemQueryProcessor.evaluate(request)
        }
        queryTask = worker
        Task { [weak self] in
            do {
                let result = try await worker.value
                guard let self, self.queryGeneration == generation else { return }
                self.visibleItems = result
            } catch {
                // A superseded query keeps the last visible result until the
                // newest generation publishes; cancellation is not a save.
            }
        }
    }
    private func replaceItem(_ item: CollectionItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
    }
    private func refreshItem(_ itemID: UUID) {
        do {
            guard let repository, let collectionID = selectedCollection?.id,
                  let refreshed = try repository.item(id: itemID, in: collectionID) else { return }
            replaceItem(refreshed)

        } catch { persistenceError = error.localizedDescription }
    }
    private static func normalizedText(_ value: String) -> String { value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func words(_ value: String) -> Set<String> { Set(normalizedText(value).split(separator: " ").map(String.init)) }
}
