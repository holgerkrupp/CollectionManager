import XCTest
import CloudKit
import SwiftData
import CollaborationCloudKit
import CollaborationCore
@testable import CollectionManager

@MainActor final class PersistenceTransportTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
    private func codec(_ container: ModelContainer, account: String = "fixture-account", environment: CollaborationEnvironment = .development) -> CollectionRecordCodec {
        CollectionRecordCodec(modelContainer: container, containerIdentifier: "iCloud.example.test", environment: environment, accountPartitionIdentifier: account)
    }

    func testHandoffRestartsEveryPageWithoutLosingLegacyBackup() async throws {
        let container = try container()
        let context = ModelContext(container)
        let repository = CollectionRepository(context: context)
        try repository.addCollection(name: "Fixture", icon: "books.vertical", subtitle: "")
        let collection = try XCTUnwrap(repository.collections().first)
        for item in CollectionPerformanceFixture.items(count: 3, collectionID: collection.id) { XCTAssertTrue(try repository.addItem(item)) }
        var actor = codec(container)
        let backup = Data([4,3,2,1])
        try await actor.beginHandoff(legacyState: backup)
        let pending = try await actor.handoffStatus(); XCTAssertEqual(pending, "journaled")
        var pages = 0
        while try await actor.bootstrapPage(limit: 1) {
            pages += 1
            actor = codec(container) // Crash/relaunch after each committed page.
            try await actor.beginHandoff(legacyState: Data([9])) // Must not overwrite backup/cursor.
            XCTAssertLessThan(pages, 30)
        }
        let beforeComplete = try await actor.handoffStatus(); XCTAssertEqual(beforeComplete, "reconciling")
        do { try await actor.completeHandoff(); XCTFail("Unacknowledged payloads must block completion") } catch { XCTAssertTrue(error is CollectionCodecError) }
        do { try await actor.finishSynchronization(); XCTFail("Real pending writes must still fail the sync pass") } catch { XCTAssertTrue(error is CollectionCodecError) }
        let beforeDrain = try await actor.pendingLocalChanges(in: .private)
        XCTAssertEqual(beforeDrain.count, 0)
        var drainPasses = 0
        while true {
            _ = try await actor.stageRepositoryMutations()
            let changes = try await actor.pendingLocalChanges(in: .private)
            if changes.isEmpty { break }
            let records = changes.compactMap { change -> CKRecord? in if case .save(let value) = change { return value }; return nil }
            let deletes = changes.compactMap { change -> CKRecord.ID? in if case .delete(let value) = change { return value }; return nil }
            try await actor.acknowledgeSentChanges(savedRecords: records, deletedRecordIDs: deletes, in: .private)
            drainPasses += 1; XCTAssertLessThan(drainPasses, 30)
        }
        try await actor.completeHandoff()
        actor = codec(container)
        let status = try await actor.handoffStatus(); XCTAssertEqual(status, "complete")
        let states = try context.fetch(FetchDescriptor<CollectionTransportState>())
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(states.allSatisfy { $0.legacyState == backup })
        let changes = try await actor.pendingLocalChanges(in: .private)
        XCTAssertTrue(changes.isEmpty)
    }

    func testFailedHandoffPageRollsBackCursorAndPayloadTogether() async throws {
        let container = try container()
        let repository = CollectionRepository(context: ModelContext(container))
        try repository.addCollection(name: "Fixture", icon: "books.vertical", subtitle: "")
        let actor = codec(container)
        try await actor.beginHandoff(legacyState: Data([1]))
        await actor.setPersistenceFailureForTesting { throw CocoaError(.fileWriteOutOfSpace) }
        do { _ = try await actor.bootstrapPage(limit: 1); XCTFail("Save should fail") } catch { XCTAssertTrue(error is RepositoryError) }
        await actor.setPersistenceFailureForTesting(nil)
        let pending = try await actor.pendingLocalChanges(in: .private); XCTAssertTrue(pending.isEmpty)
        _ = try await actor.bootstrapPage(limit: 1)
        let restored = try await codec(container).pendingLocalChanges(in: .private); XCTAssertEqual(restored.count, 0)
        let baselineCount = try await actor.unreconciledBaselineCount(); XCTAssertEqual(baselineCount, 1)
    }

    func testAccountAndEnvironmentStateArePartitionedAndGraphCannotBeAdopted() async throws {
        let container = try container()
        let first = codec(container)
        try await first.beginHandoff(legacyState: Data([1]))
        try await first.saveState(Data([2]), for: .private)
        let different = codec(container, account: "other-account")
        let state = try await different.loadState(for: .private); XCTAssertNil(state)
        do { try await different.beginHandoff(); XCTFail("Existing graph must not move to a new account") } catch { XCTAssertTrue(error is CollectionCodecError) }
        let production = codec(container, environment: .production)
        let productionState = try await production.loadState(for: .private); XCTAssertNil(productionState)
        try await production.beginHandoff()
        let firstState = try await first.loadState(for: .private); XCTAssertEqual(firstState, Data([2]))
    }

    func testAcknowledgingOlderGenerationRetainsNewEdit() async throws {
        let container = try container()
        let repository = CollectionRepository(context: ModelContext(container))
        try repository.addCollection(name: "Before", icon: "books.vertical", subtitle: "")
        var collection = try XCTUnwrap(repository.collections().first)
        let actor = codec(container)
        try await actor.beginHandoff()
        _ = try await actor.stageRepositoryMutations()
        let pending = try await actor.pendingLocalChanges(in: .private)
        let id = try XCTUnwrap(pending.first?.recordID)
        let sentValue = try await actor.record(for: id, in: .private)
        let sent = try XCTUnwrap(sentValue)
        collection.name = "After"; try repository.updateCollection(collection)
        _ = try await actor.stageRepositoryMutations()
        try await actor.acknowledgeSentChanges(savedRecords: [sent], deletedRecordIDs: [], in: .private)
        let remaining = try repository.pendingMutations()
        XCTAssertEqual(remaining.count, 1)
        let nextValue = try await actor.record(for: id, in: .private)
        let next = try XCTUnwrap(nextValue)
        XCTAssertEqual(next["name"] as? String, "After")
    }
    func testWholeCollectionDeletionRetainsEveryChildTombstoneBeforeFirstSync() async throws {
        let container = try container()
        let context = ModelContext(container)
        let repository = CollectionRepository(context: context)
        try repository.addCollection(name: "Fixture", icon: "books.vertical", subtitle: "")
        let collection = try XCTUnwrap(repository.collections().first)
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: collection.id)[0]
        XCTAssertTrue(try repository.addItem(item))
        let participant = CollaboratorIdentity(id: "fixture", displayName: "Fixture")
        try repository.setRating(for: item, value: 4, participant: participant)
        XCTAssertNotNil(try repository.addComment(to: item, text: "Fixture", participant: participant))
        let deleted = try await CollectionBackgroundRepository(container: container).deleteCollection(id: collection.id)
        XCTAssertTrue(deleted)
        let mutations = try context.fetch(FetchDescriptor<SyncMutationRecord>())
        XCTAssertEqual(Set(mutations.map(\.recordType)), Set(["Collection", "CollectionItem", "CollectionEvent", "CollectionItemRating", "CollectionItemComment"]))
        XCTAssertTrue(mutations.allSatisfy { $0.operation == "delete" })
        let actor = codec(container)
        try await actor.beginHandoff()
        _ = try await actor.stageRepositoryMutations()
        let pending = try await actor.pendingLocalChanges(in: .private)
        XCTAssertEqual(pending.count, 5)
        XCTAssertTrue(pending.allSatisfy { if case .delete = $0 { return true }; return false })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CollectionRecord>()), 0)
    }

    func testAssetSnapshotSurvivesRestagingWithoutChangingInFlightBytes() async throws {
        let container = try container()
        let repository = CollectionRepository(context: ModelContext(container))
        try repository.addCollection(name: "Fixture", icon: "books.vertical", subtitle: "")
        let collection = try XCTUnwrap(repository.collections().first)
        var item = CollectionPerformanceFixture.items(count: 1, collectionID: collection.id)[0]
        item.imageData = Data([1,2,3]); XCTAssertTrue(try repository.addItem(item))
        let actor = codec(container)
        try await actor.beginHandoff(); _ = try await actor.stageRepositoryMutations()
        let itemID = CKRecord.ID(recordName: item.id.uuidString, zoneID: CKRecordZone.ID(zoneName: "collection-\(collection.id.uuidString)", ownerName: CKCurrentUserDefaultName))
        let initialRecord = try await actor.record(for: itemID, in: .private)
        let initial = try XCTUnwrap(initialRecord)
        let initialURL = try XCTUnwrap((initial["imageAsset"] as? CKAsset)?.fileURL)
        item.imageData = Data([9,8,7]); item.updatedAt = .now
        try repository.updateItem(item)
        _ = try await actor.stageRepositoryMutations()
        XCTAssertEqual(try Data(contentsOf: initialURL), Data([1,2,3]))
        let againRecord = try await actor.record(for: itemID, in: .private)
        let again = try XCTUnwrap(againRecord)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap((again["imageAsset"] as? CKAsset)?.fileURL)), Data([1,2,3]))
        try await actor.acknowledgeSentChanges(savedRecords: [initial], deletedRecordIDs: [], in: .private)
        let newerRecord = try await actor.record(for: itemID, in: .private)
        let newer = try XCTUnwrap(newerRecord)
        let newerURL = try XCTUnwrap((newer["imageAsset"] as? CKAsset)?.fileURL)
        XCTAssertNotEqual(initialURL, newerURL)
        XCTAssertEqual(try Data(contentsOf: newerURL), Data([9,8,7]))
        XCTAssertEqual(try Data(contentsOf: initialURL), Data([1,2,3]))
    }

    func testMissingPayloadFailsWholePreparedBatchAndRetainsJournal() async throws {
        let container = try container()
        let repository = CollectionRepository(context: ModelContext(container))
        try repository.addCollection(name: "Fixture", icon: "books.vertical", subtitle: "")
        let actor = codec(container)
        try await actor.beginHandoff(); _ = try await actor.stageRepositoryMutations()
        let pending = try await actor.pendingLocalChanges(in: .private)
        let missing = CKRecord.ID(recordName: UUID().uuidString, zoneID: pending[0].recordID.zoneID)
        do {
            _ = try await actor.prepareSendBatch(pending.map(\.pendingEngineChange) + [.saveRecord(missing)], in: .private)
            XCTFail("A missing host payload must fail the batch before handing it to the engine")
        } catch { XCTAssertTrue(error is CollectionCodecError) }
        let retained = try await codec(container).pendingLocalChanges(in: .private)
        XCTAssertEqual(retained.count, pending.count)
    }

    func testViewerBacklogCannotStarveWritableMutations() async throws {
        let container = try container()
        let fixture = ModelContext(container)
        let viewerID = UUID(), ownerID = UUID()
        fixture.insert(CollectionRecord(id: viewerID, name: "Viewer")); fixture.insert(CollectionMemberRecord(collectionID: viewerID, participantID: "cloud", role: .viewer))
        fixture.insert(CollectionRecord(id: ownerID, name: "Owner")); fixture.insert(CollectionMemberRecord(collectionID: ownerID, participantID: "local", role: .owner))
        for index in 0..<450 {
            let mutation = SyncMutationRecord(collectionID: viewerID, recordName: UUID().uuidString, recordType: "CollectionItem")
            mutation.createdAt = Date(timeIntervalSince1970: Double(index)); fixture.insert(mutation)
        }
        fixture.insert(SyncMutationRecord(collectionID: ownerID, recordName: ownerID.uuidString, recordType: "Collection"))
        try fixture.save()
        let actor = codec(container); try await actor.beginHandoff()
        _ = try await actor.stageRepositoryMutations(limit: 400)
        let pending = try await actor.pendingLocalChanges(in: .private)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.recordID.recordName, ownerID.uuidString)
        let hasUnstaged = try await actor.hasEligibleUnstagedMutations(); XCTAssertFalse(hasUnstaged)
        XCTAssertEqual(try fixture.fetchCount(FetchDescriptor<SyncMutationRecord>()), 451)
    }

    func testWritableBacklogBeyondStageLimitDrainsWithoutNewUserEdits() async throws {
        let container = try container()
        let fixture = ModelContext(container), collectionID = UUID()
        fixture.insert(CollectionRecord(id: collectionID, name: "Owner")); fixture.insert(CollectionMemberRecord(collectionID: collectionID, participantID: "local", role: .owner))
        for item in CollectionPerformanceFixture.items(count: 410, collectionID: collectionID) {
            fixture.insert(ItemRecord(from: item)); fixture.insert(SyncMutationRecord(collectionID: collectionID, itemID: item.id, recordName: item.id.uuidString, recordType: "CollectionItem"))
        }
        try fixture.save()
        let actor = codec(container); try await actor.beginHandoff()
        var passes = 0
        while true {
            _ = try await actor.stageRepositoryMutations(limit: 400)
            let pending = try await actor.pendingLocalChanges(in: .private)
            if pending.isEmpty { break }
            let records = pending.compactMap { if case .save(let value) = $0 { return value }; return nil }
            try await actor.acknowledgeSentChanges(savedRecords: records, deletedRecordIDs: [], in: .private)
            passes += 1; XCTAssertLessThan(passes, 10)
        }
        XCTAssertGreaterThan(passes, 4)
        XCTAssertEqual(try fixture.fetchCount(FetchDescriptor<SyncMutationRecord>()), 0)
    }

    func testBootstrapQuarantinesAmbiguousRowsAndNeverResurrectsDeletedItems() async throws {
        let container = try container()
        let context = ModelContext(container), collectionID = UUID()
        let collection = CollectionRecord(id: collectionID, name: "Legacy")
        context.insert(collection); context.insert(CollectionMemberRecord(collectionID: collectionID, participantID: "local", role: .owner))
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: collectionID)[0]
        context.insert(ItemRecord(from: item)); try context.save() // Legacy data has no durable outgoing intent.
        let actor = codec(container); try await actor.beginHandoff()
        while try await actor.bootstrapPage(limit: 1) {}
        let pending = try await actor.pendingLocalChanges(in: .private); XCTAssertTrue(pending.isEmpty)
        let baseline = try await actor.unreconciledBaselineCount(); XCTAssertEqual(baseline, 2)
        do { try await actor.completeHandoff(); XCTFail("Ambiguous prior local rows require reconciliation") } catch { XCTAssertTrue(error is CollectionCodecError) }
        // A successful sync may defer recovery review across restarts without
        // falsely completing migration, uploading or deleting ambiguous rows.
        for _ in 0..<2 {
            let restarted = codec(container)
            try await restarted.finishSynchronization()
            let status = try await restarted.handoffStatus()
            let count = try await restarted.unreconciledBaselineCount()
            let changes = try await restarted.pendingLocalChanges(in: .private)
            XCTAssertEqual(status, "reconciling")
            XCTAssertEqual(count, baseline)
            XCTAssertTrue(changes.isEmpty)
        }
        let zone = CKRecordZone.ID(zoneName: "collection-\(collectionID.uuidString)", ownerName: CKCurrentUserDefaultName)
        try await actor.applyRemoteChanges(records: [], deletedRecordIDs: [CKRecord.ID(recordName: item.id.uuidString, zoneID: zone)], in: .private)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItemRecord>()), 0)
        let after = try await actor.pendingLocalChanges(in: .private); XCTAssertTrue(after.isEmpty)
        let snapshots = try context.fetch(FetchDescriptor<CollectionOutgoingSnapshot>())
        XCTAssertEqual(snapshots.filter { $0.operation == "baselineReconciled" }.count, 1)
    }

    func testOldSaveConflictCannotResurrectNewerLocalDelete() async throws {
        let container = try container()
        let local = CollectionRepository(context: ModelContext(container))
        try local.addCollection(name: "Fixture", icon: "books.vertical", subtitle: "")
        let collection = try XCTUnwrap(local.collections().first)
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: collection.id)[0]
        XCTAssertTrue(try local.addItem(item))
        let actor = codec(container); try await actor.beginHandoff(); _ = try await actor.stageRepositoryMutations()
        let id = CKRecord.ID(recordName: item.id.uuidString, zoneID: CKRecordZone.ID(zoneName: "collection-\(collection.id.uuidString)", ownerName: CKCurrentUserDefaultName))
        let attemptedValue = try await actor.record(for: id, in: .private)
        let attempted = try XCTUnwrap(attemptedValue)
        try local.deleteItem(item); _ = try await actor.stageRepositoryMutations()
        let server = CKRecord(recordType: "CollectionItem", recordID: id)
        server["title"] = "Server" as CKRecordValue; server["collectionID"] = collection.id.uuidString as CKRecordValue; server["updatedAt"] = Date.distantFuture as CKRecordValue
        try await actor.reconcileFailedSave(attemptedRecord: attempted, serverRecord: server, error: CKError(.serverRecordChanged), in: .private)
        XCTAssertNil(try local.item(id: item.id))
        XCTAssertTrue(try local.pendingMutations().contains { $0.recordName == item.id.uuidString && $0.operation == "delete" })
    }

}
