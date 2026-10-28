import Foundation
import SwiftData

nonisolated struct LegacyStoreRecoverySummary: Codable, Equatable, Sendable {
    var collections: Int = 0
    var items: Int = 0
    var events: Int = 0
    var pendingChanges: Int = 0
    var webSources: Int = 0
    var importedItems: Int = 0
    var sourceBackup: URL
}

nonisolated enum LegacyStoreRecoveryStatus: Equatable, Sendable {
    case none, available
    case restored(LegacyStoreRecoverySummary)
    case failed(String)
    var pausesSync: Bool { self != .none }
}

/// Old default.store is never opened in place. Only a working copy is migrated;
/// raw source/target snapshots survive cancellation, failure and process restart.
actor LegacyStoreRecovery {
    nonisolated static let receiptPartition = "CollectionManager.localLegacyRecovery.v1"
    nonisolated static var defaultSourceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("default.store")
    }
    nonisolated static func status(in container: ModelContainer, sourceURL: URL = defaultSourceURL) throws -> LegacyStoreRecoveryStatus {
        let context = ModelContext(container)
        let key = receiptPartition
        let receipts = try context.fetch(FetchDescriptor<CollectionOutgoingSnapshot>(predicate: #Predicate { $0.partition == key }))
        if let receipt = receipts.first {
            if receipt.operation == "localRecoveryReviewed" { return .none }
            return .restored(try JSONDecoder().decode(LegacyStoreRecoverySummary.self, from: receipt.mutationIDs))
        }
        guard !container.configurations.allSatisfy(\.isStoredInMemoryOnly), FileManager.default.fileExists(atPath: sourceURL.path) else { return .none }
        return .available
    }

    nonisolated static func cloudIsPaused(in container: ModelContainer) throws -> Bool {
        if ProcessInfo.processInfo.arguments.contains("--recover-legacy-default-store-once") { return true }
        if case .restored = try status(in: container) { return true }
        return false
    }

    private let target: ModelContainer
    private let sourceURL: URL
    private var prepared: ModelContainer?
    private var summary: LegacyStoreRecoverySummary?
    var failureInjector: (@Sendable () throws -> Void)?
    init(target: ModelContainer, sourceURL: URL = defaultSourceURL) { self.target = target; self.sourceURL = sourceURL }
    func setFailureForTesting(_ failure: (@Sendable () throws -> Void)?) { failureInjector = failure }

    func prepare() throws -> LegacyStoreRecoverySummary {
        if let summary { return summary }
        let manager = FileManager.default
        let base = target.configurations.first(where: { !$0.isStoredInMemoryOnly })?.url.deletingLastPathComponent()
            ?? manager.temporaryDirectory
        let backups = base.appendingPathComponent("LegacyRecovery", isDirectory: true)
        try manager.createDirectory(at: backups, withIntermediateDirectories: true)
        let raw = try PersistentStoreBootstrap.makeSafeExport(from: sourceURL, into: backups)
        // Core Data may place external binary values alongside the store. Keep
        // either historical spelling; migration is performed only on the copy.
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        for name in [stem + "_SUPPORT", "." + stem + "_SUPPORT", sourceURL.lastPathComponent + "_SUPPORT"] {
            let external = sourceURL.deletingLastPathComponent().appendingPathComponent(name)
            if manager.fileExists(atPath: external.path) { try manager.copyItem(at: external, to: raw.appendingPathComponent(name)) }
        }
        let work = backups.appendingPathComponent("Working-" + UUID().uuidString, isDirectory: true)
        try manager.copyItem(at: raw, to: work)
        // This unpublished store predates the frozen V1 sync-state shape.
        // Infer an additive lightweight upgrade only on this disposable copy;
        // do not relabel or mutate the original file or a frozen schema.
        let copy = try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations:
            ModelConfiguration(url: work.appendingPathComponent(sourceURL.lastPathComponent), cloudKitDatabase: .none))
        let context = ModelContext(copy)
        let result = LegacyStoreRecoverySummary(collections: try context.fetchCount(FetchDescriptor<CollectionRecord>()),
            items: try context.fetchCount(FetchDescriptor<ItemRecord>()), events: try context.fetchCount(FetchDescriptor<EventRecord>()),
            pendingChanges: try context.fetchCount(FetchDescriptor<SyncMutationRecord>()), webSources: try context.fetchCount(FetchDescriptor<WebSyncRecord>()), sourceBackup: raw)
        prepared = copy; summary = result
        return result
    }

    func restore() throws -> LegacyStoreRecoverySummary {
        let key = Self.receiptPartition
        let existing = try ModelContext(target).fetch(FetchDescriptor<CollectionOutgoingSnapshot>(predicate: #Predicate { $0.partition == key }))
        if let receipt = existing.first { return try JSONDecoder().decode(LegacyStoreRecoverySummary.self, from: receipt.mutationIDs) }
        var result = try prepare()
        guard let prepared else { throw RepositoryError.fetchFailed }
        let source = ModelContext(prepared), destination = ModelContext(target)
        destination.autosaveEnabled = false
        let fence = StoreWriteCoordinator.forContainer(target), expected = fence.snapshot()
        // Copy the current store under the same save gate used by all writers.
        // No engine state, locators, shares or server system fields are replaced.
        if let url = target.configurations.first(where: { !$0.isStoredInMemoryOnly })?.url {
            _ = try fence.commit(expected: nil, changedCollections: []) {
                _ = try PersistentStoreBootstrap.makeSafeExport(from: url, into: result.sourceBackup.deletingLastPathComponent())
            }
        }
        defer { if destination.hasChanges { destination.rollback() } }
        let oldMutations = try source.fetch(FetchDescriptor<SyncMutationRecord>())
        let currentMutations = try destination.fetch(FetchDescriptor<SyncMutationRecord>())
        var deletes = Set((oldMutations + currentMutations).filter { $0.operation == "delete" }.map { $0.recordType + "|" + $0.recordName })
        for row in try destination.fetch(FetchDescriptor<CollectionOutgoingSnapshot>()) where row.operation == "delete" {
            deletes.insert(row.recordType + "|" + row.recordName)
        }
        let oldCollections = try source.fetch(FetchDescriptor<CollectionRecord>())
        let currentCollections = try destination.fetch(FetchDescriptor<CollectionRecord>())
        let currentCollectionIDs = Set(currentCollections.map(\.id))
        let allowed = Set(oldCollections.filter { !deletes.contains("Collection|" + $0.id.uuidString) }.map(\.id))
        for value in oldCollections where allowed.contains(value.id) && !currentCollectionIDs.contains(value.id) { destination.insert(clone(value)) }
        var itemIDs = Set(try destination.fetch(FetchDescriptor<ItemRecord>()).map(\.id))
        let targetItems = Dictionary(try destination.fetch(FetchDescriptor<ItemRecord>()).map { ($0.id, $0.collectionID) }, uniquingKeysWith: { first, _ in first })
        for value in try source.fetch(FetchDescriptor<ItemRecord>()) where allowed.contains(value.collectionID) {
            if let existing = targetItems[value.id], existing != value.collectionID { throw RepositoryError.validation(String(localized: "A recovered item belongs to a different collection. Both libraries have been preserved.")) }
            guard !deletes.contains("CollectionItem|" + value.id.uuidString), itemIDs.insert(value.id).inserted else { continue }
            destination.insert(clone(value)); result.importedItems += 1
        }
        var eventIDs = Set(try destination.fetch(FetchDescriptor<EventRecord>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<EventRecord>()) where allowed.contains(value.collectionID) && eventIDs.insert(value.id).inserted {
            if !deletes.contains("CollectionEvent|" + value.id.uuidString) { destination.insert(clone(value)) }
        }
        var ratingIDs = Set(try destination.fetch(FetchDescriptor<ItemRatingRecord>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<ItemRatingRecord>()) where allowed.contains(value.collectionID) && itemIDs.contains(value.itemID) && !deletes.contains("CollectionItem|" + value.itemID.uuidString) && ratingIDs.insert(value.id).inserted {
            let name = CollaborationRecordNames.rating(itemID: value.itemID, participantID: value.participantID)
            if !deletes.contains("CollectionItemRating|" + name) { destination.insert(clone(value)) }
        }
        var commentIDs = Set(try destination.fetch(FetchDescriptor<ItemCommentRecord>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<ItemCommentRecord>()) where allowed.contains(value.collectionID) && itemIDs.contains(value.itemID) && !deletes.contains("CollectionItem|" + value.itemID.uuidString) && commentIDs.insert(value.id).inserted {
            if !deletes.contains("CollectionItemComment|" + CollaborationRecordNames.comment(value.id)) { destination.insert(clone(value)) }
        }
        var webIDs = Set(try destination.fetch(FetchDescriptor<WebSyncRecord>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<WebSyncRecord>()) where allowed.contains(value.collectionID) && webIDs.insert(value.id).inserted { destination.insert(clone(value)) }
        var memberIDs = Set(try destination.fetch(FetchDescriptor<CollectionMemberRecord>()).map(\.id))
        for value in try source.fetch(FetchDescriptor<CollectionMemberRecord>()) where allowed.contains(value.collectionID) && memberIDs.insert(value.id).inserted {
            guard !currentCollectionIDs.contains(value.collectionID) || value.participantID.hasPrefix("share:") else { continue }
            let copy = clone(value)
            if !copy.participantID.hasPrefix("share:") { copy.roleRawValue = "viewer" }
            destination.insert(copy)
        }
        var mutationIDs = Set(currentMutations.map(\.id))
        for value in oldMutations where mutationIDs.insert(value.id).inserted { destination.insert(clone(value)) }
        var stateCollections = Set(try destination.fetch(FetchDescriptor<CloudSyncStateRecord>()).map(\.collectionID))
        for value in try source.fetch(FetchDescriptor<CloudSyncStateRecord>()) where stateCollections.insert(value.collectionID).inserted { destination.insert(clone(value)) }
        // Reconcile recovered domain rows through the existing bounded handoff.
        // Opaque engine state, previous generations and legacy tokens stay intact.
        for value in try destination.fetch(FetchDescriptor<CollectionTransportState>()) {
            value.handoffStage = "journaled"; value.bootstrapModelIndex = 0; value.bootstrapOffset = 0
        }
        let receipt = CollectionOutgoingSnapshot(partition: Self.receiptPartition, scope: "local", zoneName: "", ownerName: "", recordName: "default.store")
        receipt.operation = "localRecoveryReceipt"; receipt.recordType = "LocalRecoveryReceipt"
        receipt.mutationIDs = try JSONEncoder().encode(result)
        destination.insert(receipt)
        try failureInjector?()
        _ = try fence.commit(expected: expected, changedCollections: StoreWriteCoordinator.changedCollections(in: destination)) { try destination.save() }
        return result
    }

    func resumeCloudAfterReview() throws {
        let context = ModelContext(target), key = Self.receiptPartition
        context.autosaveEnabled = false
        for receipt in try context.fetch(FetchDescriptor<CollectionOutgoingSnapshot>(predicate: #Predicate { $0.partition == key })) {
            receipt.operation = "localRecoveryReviewed"
        }
        _ = try StoreWriteCoordinator.forContainer(target).commit(expected: nil, changedCollections: []) { try context.save() }
    }
    private func clone(_ source: CollectionRecord) -> CollectionRecord {
        let value = CollectionRecord(id: source.id, name: source.name)
        value.id = source.id
        value.name = source.name
        value.icon = source.icon
        value.subtitle = source.subtitle
        value.createdAt = source.createdAt
        value.updatedAt = source.updatedAt
        value.settingsJSON = source.settingsJSON
        return value
    }

    private func clone(_ source: CollectionMemberRecord) -> CollectionMemberRecord {
        let value = CollectionMemberRecord(collectionID: source.collectionID, participantID: source.participantID, role: .viewer)
        value.id = source.id
        value.collectionID = source.collectionID
        value.participantID = source.participantID
        value.displayName = source.displayName
        value.roleRawValue = source.roleRawValue
        value.updatedAt = source.updatedAt
        return value
    }

    private func clone(_ source: ItemRecord) -> ItemRecord {
        let value = ItemRecord(from: source.domain)
        value.id = source.id
        value.collectionID = source.collectionID
        value.title = source.title
        value.brand = source.brand
        value.variant = source.variant
        value.itemDescription = source.itemDescription
        value.stateRawValue = source.stateRawValue
        value.quantity = source.quantity
        value.barcodeValue = source.barcodeValue
        value.barcodeType = source.barcodeType
        value.createdAt = source.createdAt
        value.updatedAt = source.updatedAt
        value.consumedAt = source.consumedAt
        value.tagsJSON = source.tagsJSON
        value.dateTagsJSON = source.dateTagsJSON
        value.metadataJSON = source.metadataJSON
        value.sourceSnapshotJSON = source.sourceSnapshotJSON
        value.imageSystemName = source.imageSystemName
        value.imageData = source.imageData
        value.importSourceKey = source.importSourceKey
        return value
    }

    private func clone(_ source: ItemRatingRecord) -> ItemRatingRecord {
        let value = ItemRatingRecord(itemID: source.itemID, collectionID: source.collectionID, participantID: source.participantID, participantName: source.participantName, value: source.value)
        value.id = source.id
        value.itemID = source.itemID
        value.collectionID = source.collectionID
        value.participantID = source.participantID
        value.participantName = source.participantName
        value.value = source.value
        value.updatedAt = source.updatedAt
        return value
    }

    private func clone(_ source: ItemCommentRecord) -> ItemCommentRecord {
        let value = ItemCommentRecord(itemID: source.itemID, collectionID: source.collectionID, participantID: source.participantID, participantName: source.participantName, text: source.text)
        value.id = source.id
        value.itemID = source.itemID
        value.collectionID = source.collectionID
        value.participantID = source.participantID
        value.participantName = source.participantName
        value.text = source.text
        value.createdAt = source.createdAt
        value.updatedAt = source.updatedAt
        return value
    }

    private func clone(_ source: EventRecord) -> EventRecord {
        let value = EventRecord(itemID: source.itemID, collectionID: source.collectionID, type: source.type)
        value.id = source.id
        value.itemID = source.itemID
        value.collectionID = source.collectionID
        value.timestamp = source.timestamp
        value.type = source.type
        value.note = source.note
        return value
    }

    private func clone(_ source: WebSyncRecord) -> WebSyncRecord {
        let value = WebSyncRecord(collectionID: source.collectionID, urlString: source.urlString, tableName: source.tableName, headers: [], mapping: [])
        value.id = source.id
        value.collectionID = source.collectionID
        value.urlString = source.urlString
        value.tableName = source.tableName
        value.headersJSON = source.headersJSON
        value.mappingJSON = source.mappingJSON
        value.conditionalRulesJSON = source.conditionalRulesJSON
        value.tagSeparators = source.tagSeparators
        value.splitTagsOnWhitespace = source.splitTagsOnWhitespace
        value.generateTagsFromTitle = source.generateTagsFromTitle
        value.titleTagModeRawValue = source.titleTagModeRawValue
        value.titleSeparators = source.titleSeparators
        value.intervalMinutes = source.intervalMinutes
        value.enabled = source.enabled
        value.addNewItems = source.addNewItems
        value.updateExistingStates = source.updateExistingStates
        value.fixedStateRawValue = source.fixedStateRawValue
        value.lastSyncAt = source.lastSyncAt
        value.lastError = source.lastError
        return value
    }

    private func clone(_ source: SyncMutationRecord) -> SyncMutationRecord {
        let value = SyncMutationRecord(collectionID: source.collectionID, recordName: source.recordName, recordType: source.recordType, operation: source.operation)
        value.id = source.id
        value.collectionID = source.collectionID
        value.itemID = source.itemID
        value.recordName = source.recordName
        value.recordType = source.recordType
        value.operation = source.operation
        value.createdAt = source.createdAt
        value.attempts = source.attempts
        value.lastError = source.lastError
        return value
    }

    private func clone(_ source: CloudSyncStateRecord) -> CloudSyncStateRecord {
        let value = CloudSyncStateRecord(collectionID: source.collectionID)
        value.id = source.id
        value.collectionID = source.collectionID
        value.stateRawValue = source.stateRawValue
        value.lastSyncedAt = source.lastSyncedAt
        value.lastError = source.lastError
        value.pendingCount = source.pendingCount
        value.privateChangeTokenData = source.privateChangeTokenData
        value.sharedChangeTokenData = source.sharedChangeTokenData
        value.recoveryAttempts = source.recoveryAttempts
        return value
    }

}
