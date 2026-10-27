import XCTest
import CloudKit
import SwiftData
import CollaborationCore
@testable import CollectionManager

@MainActor final class CodecWriteFenceTests: XCTestCase {
    func testCompletedSeparateContextWritesRemainVisibleToCachedRepositoryAndCodec() async throws {
        let container = try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations:
            ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let original = CollectionRepository(context: ModelContext(container))
        try original.addCollection(name: "Original", icon: "books.vertical", subtitle: "Old subtitle")
        let collection = try XCTUnwrap(original.collections().first)
        var seededItem = CollectionPerformanceFixture.items(count: 1, collectionID: collection.id)[0]
        seededItem.state = .stored
        _ = try original.addItem(seededItem)
        // Register both models in the long-lived original context before the other writer runs.
        _ = try original.items(in: collection.id)
        let codec = CollectionRecordCodec(modelContainer: container, containerIdentifier: "iCloud.example.cached",
            environment: .development, accountPartitionIdentifier: "synthetic-account")
        try await codec.beginHandoff()
        let zone = CKRecordZone.ID(zoneName: "collection-\(collection.id.uuidString)", ownerName: CKCurrentUserDefaultName)
        try await codec.registerCollection(collectionID: collection.id, zoneID: zone, scope: .private, role: .owner)
        _ = try await codec.sharePlans()

        let other = CollectionRepository(context: ModelContext(container))
        var editedItem = try XCTUnwrap(other.item(id: seededItem.id, in: collection.id))
        editedItem.brand = "Newly committed brand"
        editedItem.updatedAt = .now
        try other.updateItem(editedItem)
        var editedCollection = try XCTUnwrap(other.collections().first)
        editedCollection.subtitle = "Newly committed subtitle"
        try other.updateCollection(editedCollection)

        _ = try original.bulkUpdateState(for: [seededItem.id], in: collection.id, to: .consumed)
        let fresh = CollectionRepository(context: ModelContext(container))
        let storedItem = try XCTUnwrap(fresh.item(id: seededItem.id, in: collection.id))
        XCTAssertEqual(storedItem.brand, "Newly committed brand",
                       "A later status-only transaction must preserve a completed separate-context brand edit")
        XCTAssertEqual(storedItem.state, .consumed)

        let remote = CKRecord(recordType: "Collection", recordID: CKRecord.ID(recordName: collection.id.uuidString, zoneID: zone))
        remote["name"] = "Remote renamed collection"
        remote["updatedAt"] = Date.distantFuture
        // No subtitle in this older client's payload: retain the latest committed subtitle.
        // Clear only transport intent so this exercises remote application rather than local-intent protection.
        try other.removeMutations(try other.pendingMutations())
        try await codec.applyRemoteChanges(records: [remote], deletedRecordIDs: [], in: .private)
        let final = try XCTUnwrap(CollectionRepository(context: ModelContext(container)).collections().first)
        XCTAssertEqual(final.name, "Remote renamed collection")
        XCTAssertEqual(final.subtitle, "Newly committed subtitle")
    }

    func testStaleRemoteApplyCannotOverwriteNewerCommittedLocalValue() async throws {
        let container = try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations:
            ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let id = UUID()
        let seed = ModelContext(container)
        seed.insert(CollectionRecord(id: id, name: "Original", createdAt: .distantPast, updatedAt: .distantPast))
        try seed.save()
        let codec = CollectionRecordCodec(modelContainer: container, containerIdentifier: "iCloud.example.fence",
            environment: .development, accountPartitionIdentifier: "synthetic-account")
        try await codec.beginHandoff()
        let zone = CKRecordZone.ID(zoneName: "collection-\(id.uuidString)", ownerName: CKCurrentUserDefaultName)
        try await codec.registerCollection(collectionID: id, zoneID: zone, scope: .private, role: .owner)
        let fence = StoreWriteCoordinator.forContainer(container)
        let initial = fence.snapshot()
        await codec.setPersistenceFailureForTesting {
            let context = ModelContext(container)
            let expected = fence.snapshot()
            let root = try XCTUnwrap(context.fetch(FetchDescriptor<CollectionRecord>()).first)
            root.name = "Newer manual edit"
            root.updatedAt = .distantFuture
            _ = try fence.commit(expected: expected, changedCollections: [id]) { try context.save() }
        }
        let record = CKRecord(recordType: "Collection", recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zone))
        record["name"] = "Stale remote value"
        record["updatedAt"] = Date()
        do {
            try await codec.applyRemoteChanges(records: [record], deletedRecordIDs: [], in: .private)
            XCTFail("An interleaving local commit must reject the stale remote transaction")
        } catch { XCTAssertTrue(error is RepositoryError) }
        await codec.setPersistenceFailureForTesting(nil)
        let verification = ModelContext(container)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<CollectionRecord>()).first?.name, "Newer manual edit")
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<CollectionCloudRecordState>()), 0,
                       "A rejected remote transaction must also roll back its transport metadata")
        XCTAssertEqual(fence.snapshot()[id], (initial[id] ?? 0) + 1)
        // Retry uses a new operation snapshot and preserves the newer domain value.
        try await codec.applyRemoteChanges(records: [record], deletedRecordIDs: [], in: .private)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CollectionRecord>()).first?.name, "Newer manual edit")
    }

    func testStatePersistenceAndUnchangedAccessDoNotAdvanceDomainRevision() async throws {
        let container = try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations:
            ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let id = UUID()
        let context = ModelContext(container)
        context.insert(CollectionRecord(id: id, name: "Fixture"))
        try context.save()
        let codec = CollectionRecordCodec(modelContainer: container, containerIdentifier: "iCloud.example.fence",
            environment: .development, accountPartitionIdentifier: "synthetic-account")
        try await codec.beginHandoff()
        try await codec.registerCollection(collectionID: id,
            zoneID: CKRecordZone.ID(zoneName: "fixture", ownerName: CKCurrentUserDefaultName), scope: .private, role: .owner)
        let fence = StoreWriteCoordinator.forContainer(container)
        let before = fence.snapshot()
        try await codec.saveState(Data([1, 2, 3]), for: .private)
        try await codec.updateAccess(collectionID: id, role: .owner)
        XCTAssertEqual(fence.snapshot(), before)
        let saved = try await codec.loadState(for: .private)
        XCTAssertEqual(saved, Data([1, 2, 3]))
        try await codec.updateAccess(collectionID: id, role: .viewer)
        XCTAssertEqual(fence.snapshot()[id], (before[id] ?? 0) + 1)
    }
}
