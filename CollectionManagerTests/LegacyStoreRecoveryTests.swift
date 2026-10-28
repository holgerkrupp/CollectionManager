import XCTest
import SwiftData
@testable import CollectionManager

@MainActor final class LegacyStoreRecoveryTests: XCTestCase {
    private func fixture() throws -> (URL, ModelContainer, ModelContainer, UUID, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Legacy-recovery-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("default.store")
        let old = try ModelContainer(for: Schema(CollectionManagerSchemaV1.models), configurations: ModelConfiguration(url: sourceURL, cloudKitDatabase: .none))
        let current = try PersistentStoreBootstrap.makeContainer(at: root.appendingPathComponent("Current/CollectionManager.store"))
        let source = ModelContext(old); source.autosaveEnabled = false
        let id = UUID()
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: id)[0]
        let itemID = item.id
        source.insert(CollectionRecord(id: id, name: "Old library", settingsJSON: "{\"custom\":true}"))
        source.insert(CollectionMemberRecord(collectionID: id, participantID: "old-account", role: .owner))
        let value = ItemRecord(from: item)
        value.tagsJSON = "[\"Keep exact bytes\"]"; value.metadataJSON = "{\"legacy\":{\"string\":{\"_0\":\"value\"}}}"
        value.imageData = Data([1, 2, 3]); source.insert(value)
        let event = EventRecord(itemID: itemID, collectionID: id, type: "legacy", note: "Retain history")
        source.insert(event)
        source.insert(ItemRatingRecord(itemID: itemID, collectionID: id, participantID: "person", participantName: "Person", value: 4))
        source.insert(ItemCommentRecord(itemID: itemID, collectionID: id, participantID: "person", participantName: "Person", text: "Retain comment"))
        source.insert(WebSyncRecord(collectionID: id, urlString: "https://example.invalid", tableName: "Source", headers: ["Title"], mapping: [.standard(.title)]))
        let state = CloudSyncStateRecord(collectionID: id); state.privateChangeTokenData = Data([8, 9]); source.insert(state)
        source.insert(SyncMutationRecord(collectionID: id, itemID: itemID, recordName: itemID.uuidString, recordType: "CollectionItem"))
        try source.save()
        return (sourceURL, old, current, id, itemID)
    }

    func testCopiesOriginalAndRestoresEveryDomainTypeWithoutGrantingLegacyOwnerAccess() async throws {
        let (url, old, current, id, itemID) = try fixture()
        let bytes = try Data(contentsOf: url), wal = try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))
        XCTAssertEqual(try LegacyStoreRecovery.status(in: current, sourceURL: url), .available)
        let service = LegacyStoreRecovery(target: current, sourceURL: url)
        let preview = try await service.prepare()
        XCTAssertEqual(preview.items, 1)
        let result = try await service.restore()
        XCTAssertEqual(result.importedItems, 1)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")), wal)
        let context = ModelContext(current)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CollectionRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItemRatingRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItemCommentRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WebSyncRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncMutationRecord>()), 1)
        let recovered = try XCTUnwrap(context.fetch(FetchDescriptor<ItemRecord>()).first)
        let original = try XCTUnwrap(ModelContext(old).fetch(FetchDescriptor<ItemRecord>()).first)
        XCTAssertEqual(recovered.id, itemID); XCTAssertEqual(recovered.collectionID, id)
        XCTAssertEqual(recovered.tagsJSON, original.tagsJSON); XCTAssertEqual(recovered.metadataJSON, original.metadataJSON)
        XCTAssertEqual(recovered.imageData, original.imageData)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CloudSyncStateRecord>()).first?.privateChangeTokenData, Data([8, 9]))
        XCTAssertEqual(try context.fetch(FetchDescriptor<CollectionMemberRecord>()).first?.roleRawValue, "viewer")
        XCTAssertTrue(try LegacyStoreRecovery.status(in: current, sourceURL: url).pausesSync)
    }

    func testCurrentValuesAuthorityAndTransportSurviveAndRetryDoesNotDuplicate() async throws {
        let (url, old, current, id, _) = try fixture()
        let context = ModelContext(current)
        context.insert(CollectionRecord(id: id, name: "Current wins"))
        context.insert(CollectionMemberRecord(collectionID: id, participantID: "cloud", role: .viewer))
        let item = try XCTUnwrap(ModelContext(old).fetch(FetchDescriptor<ItemRecord>()).first)
        let currentItem = ItemRecord(from: item.domain); currentItem.title = "Current item"
        context.insert(currentItem)
        let state = CollectionTransportState(partition: "current-account", scope: "private")
        state.engineState = Data([4, 5]); state.handoffStage = "complete"; context.insert(state)
        let owner = CollectionTransportOwner(graphPartition: "graph", accountPartition: "current-account"); context.insert(owner)
        try context.save()
        let service = LegacyStoreRecovery(target: current, sourceURL: url)
        _ = try await service.restore()
        _ = try await LegacyStoreRecovery(target: current, sourceURL: url).restore()
        let fresh = ModelContext(current)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CollectionRecord>()).first?.name, "Current wins")
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ItemRecord>()).first?.title, "Current item")
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<ItemRecord>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<CollectionMemberRecord>()), 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CollectionMemberRecord>()).first?.roleRawValue, "viewer")
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CollectionTransportState>()).first?.engineState, Data([4, 5]))
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CollectionTransportState>()).first?.handoffStage, "journaled")
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<CollectionTransportOwner>()).first?.accountPartition, "current-account")
        try await service.resumeCloudAfterReview()
        XCTAssertFalse(try LegacyStoreRecovery.status(in: current, sourceURL: url).pausesSync)
        _ = try await LegacyStoreRecovery(target: current, sourceURL: url).restore()
        XCTAssertEqual(try ModelContext(current).fetchCount(FetchDescriptor<CollectionOutgoingSnapshot>()), 1)
        XCTAssertFalse(try LegacyStoreRecovery.status(in: current, sourceURL: url).pausesSync)
    }

    func testFailedCommitRollsBackReceiptDataAndLegacyQueueThenRetrySucceeds() async throws {
        let (url, _, current, _, _) = try fixture()
        let service = LegacyStoreRecovery(target: current, sourceURL: url)
        await service.setFailureForTesting { throw CocoaError(.fileWriteOutOfSpace) }
        do { _ = try await service.restore(); XCTFail("Injected failure must roll back") } catch {}
        let context = ModelContext(current)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItemRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncMutationRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CollectionOutgoingSnapshot>()), 0)
        await service.setFailureForTesting(nil)
        let result = try await service.restore()
        XCTAssertEqual(result.importedItems, 1)
    }

    func testPendingDeletePreventsResurrectionAndRetainsBothQueues() async throws {
        let (url, _, current, id, itemID) = try fixture()
        let context = ModelContext(current)
        context.insert(CollectionRecord(id: id, name: "Current"))
        let deletion = SyncMutationRecord(collectionID: id, itemID: itemID, recordName: itemID.uuidString, recordType: "CollectionItem", operation: "delete")
        context.insert(deletion); try context.save()
        let result = try await LegacyStoreRecovery(target: current, sourceURL: url).restore()
        XCTAssertEqual(result.importedItems, 0)
        let fresh = ModelContext(current)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<ItemRecord>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<SyncMutationRecord>()), 2)
        XCTAssertTrue(try fresh.fetch(FetchDescriptor<SyncMutationRecord>()).contains { $0.id == deletion.id && $0.operation == "delete" })
    }

    func testPrivatePhoneBackupRecoveryWhenExplicitlySupplied() async throws {
        let path = ProcessInfo.processInfo.environment["CM_RECOVERY_BACKUP"]
        guard let root = path else { throw XCTSkip("Private recovery backup not supplied") }
        // Only opt in on the recovery host. This private data never becomes a fixture in Git.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Real-recovery-copy-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: root).appendingPathComponent("Application Support"), to: temporary)
        let current = try PersistentStoreBootstrap.makeContainer(at: temporary.appendingPathComponent("CollectionManager/CollectionManager.store"))
        let sourceURL = temporary.appendingPathComponent("default.store")
        let service = LegacyStoreRecovery(target: current, sourceURL: sourceURL)
        let preview = try await service.prepare()
        XCTAssertEqual(preview.collections, 4); XCTAssertEqual(preview.items, 525); XCTAssertEqual(preview.events, 2887); XCTAssertEqual(preview.pendingChanges, 22)
        let result = try await service.restore()
        XCTAssertEqual(result.importedItems, 525)
        let reopened = try PersistentStoreBootstrap.makeContainer(at: temporary.appendingPathComponent("CollectionManager/CollectionManager.store"))
        let context = ModelContext(reopened)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItemRecord>()), 525)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), 2887)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncMutationRecord>()), 22)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WebSyncRecord>()), 1)
        let repeated = try await LegacyStoreRecovery(target: reopened, sourceURL: sourceURL).restore()
        XCTAssertEqual(repeated.importedItems, 525)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItemRecord>()), 525)
    }
}
