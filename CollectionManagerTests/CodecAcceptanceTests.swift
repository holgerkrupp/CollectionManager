import XCTest
import CloudKit
import SwiftData
import CollaborationCloudKit
import CollaborationCore
@testable import CollectionManager

@MainActor final class CodecAcceptanceTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations:
                            ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func codec(_ container: ModelContainer, account: String = "synthetic-account", environment: CollaborationEnvironment = .development) -> CollectionRecordCodec {
        CollectionRecordCodec(modelContainer: container, containerIdentifier: "iCloud.example.codec-tests",
                              environment: environment, accountPartitionIdentifier: account)
    }

    private func setup() async throws -> (ModelContainer, CollectionRecordCodec, UUID, CKRecordZone.ID) {
        let container = try container()
        let id = UUID()
        let context = ModelContext(container)
        context.insert(CollectionRecord(id: id, name: "Fixture", createdAt: .distantPast, updatedAt: .distantPast))
        try context.save()
        let actor = codec(container)
        try await actor.beginHandoff()
        let zone = CKRecordZone.ID(zoneName: "collection-\(id.uuidString)", ownerName: CKCurrentUserDefaultName)
        try await actor.registerCollection(collectionID: id, zoneID: zone, scope: .private, role: .owner)
        return (container, actor, id, zone)
    }

    private func item(_ id: UUID = UUID(), collectionID: UUID, zone: CKRecordZone.ID,
                      title: String = "Remote", time: TimeInterval = 200) -> CKRecord {
        let record = CKRecord(recordType: "CollectionItem", recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zone))
        record["title"] = title; record["collectionID"] = collectionID.uuidString
        record["updatedAt"] = Date(timeIntervalSince1970: time)
        record["createdAt"] = Date(timeIntervalSince1970: 100)
        record.parent = CKRecord.Reference(recordID: CKRecord.ID(recordName: collectionID.uuidString, zoneID: zone), action: .none)
        return record
    }

    func testPrivateShadowCannotGrantAccessOverwriteOrDeleteJoinedData() async throws {
        let (container, actor, collectionID, privateZone) = try await setup()
        let sharedZone = CKRecordZone.ID(zoneName: privateZone.zoneName, ownerName: "synthetic-owner")
        try await actor.registerCollection(collectionID: collectionID, zoneID: sharedZone, scope: .shared, role: .viewer)
        let child = item(collectionID: collectionID, zone: sharedZone, title: "Joined value")
        try await actor.applyRemoteChanges(records: [child], deletedRecordIDs: [], in: .shared)
        let shadowRoot = CKRecord(recordType: "Collection", recordID: CKRecord.ID(recordName: collectionID.uuidString, zoneID: privateZone))
        shadowRoot["name"] = "Private shadow"; shadowRoot["updatedAt"] = Date.distantFuture
        let shadowChild = item(try XCTUnwrap(UUID(uuidString: child.recordID.recordName)), collectionID: collectionID, zone: privateZone, title: "Wrong private value", time: 9_999)
        try await actor.applyRemoteChanges(records: [shadowRoot, shadowChild], deletedRecordIDs: [], in: .private)
        try await actor.applyRemoteChanges(records: [], deletedRecordIDs: [shadowChild.recordID], in: .private)
        let repository = CollectionRepository(context: ModelContext(container))
        let collection = try XCTUnwrap(repository.collections().first)
        XCTAssertEqual(collection.name, "Fixture"); XCTAssertEqual(collection.role, .viewer)
        XCTAssertEqual(try repository.items(in: collectionID).first?.title, "Joined value")
        let privateZones = try await actor.knownZones(in: .private)
        XCTAssertTrue(privateZones.isEmpty)
        let candidates = try await actor.legacyCandidates()
        XCTAssertEqual(candidates.count, 1)
        XCTAssertFalse(try XCTUnwrap(candidates.first).canUpload)
        do { try await actor.authorizeBaselineUpload(snapshotID: candidates[0].id); XCTFail("A private shadow cannot authorize a shared write") }
        catch { XCTAssertTrue(error is RepositoryError) }
    }

    func testConflictingJoinedLocationsDoNotReplaceExistingShareLocator() async throws {
        let (_, actor, collectionID, privateZone) = try await setup()
        let original = CKRecordZone.ID(zoneName: privateZone.zoneName, ownerName: "synthetic-owner-A")
        let conflicting = CKRecordZone.ID(zoneName: privateZone.zoneName, ownerName: "synthetic-owner-B")
        try await actor.registerCollection(collectionID: collectionID, zoneID: original, scope: .shared, role: .viewer)
        do { try await actor.registerCollection(collectionID: collectionID, zoneID: conflicting, scope: .shared, role: .editor); XCTFail("Conflicting shares must not replace stable routing") }
        catch { XCTAssertTrue(error is CollectionCodecError) }
        let retained = try await actor.knownZones(in: .shared)
        XCTAssertEqual(retained, [original])
    }

    func testExplicitAcknowledgedDeleteResolvesOnlyItsOwnLegacyCandidate() async throws {
        let (container, actor, collectionID, zone) = try await setup()
        let context = ModelContext(container)
        let local = CollectionPerformanceFixture.items(count: 1, collectionID: collectionID)[0]
        context.insert(ItemRecord(from: local)); try context.save()
        while try await actor.bootstrapPage(limit: 20) { }
        let before = try await actor.unreconciledBaselineCount(); XCTAssertEqual(before, 2)
        let repository = CollectionRepository(context: ModelContext(container))
        try repository.deleteItem(local)
        _ = try await actor.stageRepositoryMutations()
        try await actor.acknowledgeSentChanges(savedRecords: [], deletedRecordIDs: [CKRecord.ID(recordName: local.id.uuidString, zoneID: zone)], in: .private)
        let after = try await actor.unreconciledBaselineCount(); XCTAssertEqual(after, 1)
        XCTAssertTrue(try repository.items(in: collectionID).isEmpty)
    }

    func testOnlyExplicitNewCollectionIntentAuthorizesZoneCreation() async throws {
        let (container, actor, legacyID, _) = try await setup()
        let initiallyAuthorized = try await actor.authorizedNewPrivateZones()
        XCTAssertTrue(initiallyAuthorized.isEmpty)
        let repository = CollectionRepository(context: ModelContext(container))
        try repository.addCollection(name: "Explicit new collection", icon: "books.vertical", subtitle: "")
        let newID = try XCTUnwrap(repository.collections().first(where: { $0.id != legacyID })?.id)
        let authorized = try await actor.authorizedNewPrivateZones()
        XCTAssertEqual(authorized.map(\.zoneName), ["collection-\(newID.uuidString)"])
    }

    func testDowngradedViewerCannotSendAlreadyQueuedEngineSaves() async throws {
        let (container, actor, collectionID, zone) = try await setup()
        let record = item(collectionID: collectionID, zone: zone)
        try await actor.stageLocalChanges([.save(record)], advancingTo: nil, in: .private)
        try await actor.updateAccess(collectionID: collectionID, role: .viewer)
        let batch = try await actor.prepareSendBatch([.saveRecord(record.recordID)], in: .private)
        XCTAssertNil(batch)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<CollectionOutgoingSnapshot>()), 1)
        try await actor.updateAccess(collectionID: collectionID, role: .editor)
        let retained = try await actor.pendingLocalChanges(in: .private)
        XCTAssertEqual(retained.map(\.recordID), [record.recordID])
    }

    func testLeavingSharedScopeRetainsDataAndDoesNotDisablePrivateScope() async throws {
        let (container, actor, privateID, privateZone) = try await setup()
        let joinedID = UUID()
        let context = ModelContext(container)
        context.insert(CollectionRecord(id: joinedID, name: "Joined")); try context.save()
        let joinedZone = CKRecordZone.ID(zoneName: "collection-\(joinedID.uuidString)", ownerName: "synthetic-owner")
        try await actor.registerCollection(collectionID: joinedID, zoneID: joinedZone, scope: .shared, role: .editor)
        try await actor.stageLocalChanges([.save(item(collectionID: joinedID, zone: joinedZone))], advancingTo: nil, in: .shared)
        try await actor.deactivateSharedCollection(collectionID: joinedID)
        let privateZones = try await actor.knownZones(in: .private)
        let sharedZones = try await actor.knownZones(in: .shared)
        XCTAssertEqual(privateZones, [privateZone]); XCTAssertTrue(sharedZones.isEmpty)
        let repository = CollectionRepository(context: ModelContext(container))
        XCTAssertEqual(try repository.collections().first(where: { $0.id == privateID })?.role, .owner)
        XCTAssertEqual(try repository.collections().first(where: { $0.id == joinedID })?.role, .viewer)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<CollectionOutgoingSnapshot>()), 1)
    }

    func testChildOnlyDeltasDuplicateEventsAndDeletesApplyWithoutLocalEcho() async throws {
        let (container, actor, collectionID, zone) = try await setup()
        let child = item(collectionID: collectionID, zone: zone)
        let event = CKRecord(recordType: "CollectionEvent", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zone))
        event["itemID"] = child.recordID.recordName; event["type"] = "created"
        event["timestamp"] = Date(timeIntervalSince1970: 200)
        try await actor.applyRemoteChanges(records: [child, event, event], deletedRecordIDs: [], in: .private)
        var context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CollectionRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItemRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncMutationRecord>()), 0)
        try await actor.applyRemoteChanges(records: [], deletedRecordIDs: [child.recordID], in: .private)
        context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItemRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), 0)
        let pending = try await actor.pendingLocalChanges(in: .private)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncMutationRecord>()), 0)
    }

    func testSameZoneNameWithDifferentOwnersAndScopesRoutesToSeparateCollections() async throws {
        let container = try container()
        let actor = codec(container)
        try await actor.beginHandoff()
        let privateID = UUID(), firstID = UUID(), secondID = UUID()
        let privateZone = CKRecordZone.ID(zoneName: "same-zone", ownerName: CKCurrentUserDefaultName)
        let firstZone = CKRecordZone.ID(zoneName: "same-zone", ownerName: "synthetic-owner-A")
        let secondZone = CKRecordZone.ID(zoneName: "same-zone", ownerName: "synthetic-owner-B")
        let context = ModelContext(container)
        for id in [privateID, firstID, secondID] { context.insert(CollectionRecord(id: id, name: "Fixture")) }
        try context.save()
        try await actor.registerCollection(collectionID: privateID, zoneID: privateZone, scope: .private, role: .owner)
        try await actor.registerCollection(collectionID: firstID, zoneID: firstZone, scope: .shared, role: .editor)
        try await actor.registerCollection(collectionID: secondID, zoneID: secondZone, scope: .shared, role: .viewer)
        try await actor.applyRemoteChanges(records: [item(collectionID: privateID, zone: privateZone, title: "Private")], deletedRecordIDs: [], in: .private)
        try await actor.applyRemoteChanges(records: [item(collectionID: firstID, zone: firstZone, title: "First"), item(collectionID: secondID, zone: secondZone, title: "Second")], deletedRecordIDs: [], in: .shared)
        let records = try ModelContext(container).fetch(FetchDescriptor<ItemRecord>())
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: records.map { ($0.collectionID, $0.title) }), [privateID: "Private", firstID: "First", secondID: "Second"])
        let privateZones = try await actor.knownZones(in: .private)
        let sharedZones = try await actor.knownZones(in: .shared)
        XCTAssertEqual(Set(privateZones), [privateZone])
        XCTAssertEqual(Set(sharedZones), [firstZone, secondZone])
    }

    func testJournalCannotLeakAcrossAccountEnvironmentOrDatabaseScope() async throws {
        let (container, actor, collectionID, zone) = try await setup()
        let child = item(collectionID: collectionID, zone: zone)
        try await actor.stageLocalChanges([.save(child)], advancingTo: Data([1]), in: .private)
        let otherAccount = codec(container, account: "different-synthetic-account")
        let production = codec(container, environment: .production)
        let accountPending = try await otherAccount.pendingLocalChanges(in: .private)
        let productionPending = try await production.pendingLocalChanges(in: .private)
        let sharedPending = try await actor.pendingLocalChanges(in: .shared)
        XCTAssertTrue(accountPending.isEmpty)
        XCTAssertTrue(productionPending.isEmpty)
        XCTAssertTrue(sharedPending.isEmpty)
        do { try await otherAccount.beginHandoff(); XCTFail("An existing graph cannot silently move accounts") }
        catch { XCTAssertTrue(error is CollectionCodecError) }
        let original = try await actor.pendingLocalChanges(in: .private)
        XCTAssertEqual(original.map(\.recordID), [child.recordID])
    }

    func testPendingDeleteAndFailedRecordRemainUntilTheirOwnAcknowledgementsAcrossRestart() async throws {
        let (container, actor, collectionID, zone) = try await setup()
        let saved = item(collectionID: collectionID, zone: zone)
        let failed = item(collectionID: collectionID, zone: zone)
        let deleted = CKRecord.ID(recordName: UUID().uuidString, zoneID: zone)
        try await actor.stageLocalChanges([.save(saved), .save(failed), .delete(deleted)], advancingTo: nil, in: .private)
        _ = try await actor.record(for: saved.recordID, in: .private)
        _ = try await actor.record(for: failed.recordID, in: .private)
        try await actor.acknowledgeSentChanges(savedRecords: [saved], deletedRecordIDs: [], in: .private)
        try await actor.reconcileFailedSave(attemptedRecord: failed, serverRecord: nil, error: CKError(.requestRateLimited), in: .private)
        try await actor.retainFailedDelete(deleted, error: CKError(.networkFailure), in: .private)
        // Repeated failures retain one local diagnostic per record, without
        // turning diagnostics into outgoing changes or retiring failed work.
        try await actor.reconcileFailedSave(attemptedRecord: failed, serverRecord: nil, error: CKError(.requestRateLimited), in: .private)
        let failures = try ModelContext(container).fetch(FetchDescriptor<CollectionOutgoingSnapshot>()).filter { $0.operation == "syncFailure" }
        XCTAssertEqual(failures.count, 2)
        let detail = try XCTUnwrap(failures.first { $0.recordName == failed.recordID.recordName }?.recordArchive)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: detail)["code"], String(CKError.Code.requestRateLimited.rawValue))
        let restarted = codec(container)
        let pending = try await restarted.pendingLocalChanges(in: .private)
        XCTAssertEqual(Set(pending.map(\.recordID)), [failed.recordID, deleted])
        XCTAssertTrue(pending.contains { if case .delete(let id) = $0 { id == deleted } else { false } })
        try await restarted.acknowledgeSentChanges(savedRecords: [], deletedRecordIDs: [deleted], in: .private)
        let remaining = try await codec(container).pendingLocalChanges(in: .private)
        XCTAssertEqual(remaining.map(\.recordID), [failed.recordID])
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<CollectionOutgoingSnapshot>()).filter { $0.operation == "syncFailure" }.count, 1)
    }

    func testMalformedRecordRollsBackWholeFetchedBatch() async throws {
        let (container, actor, collectionID, zone) = try await setup()
        let good = item(collectionID: collectionID, zone: zone)
        let bad = item(collectionID: UUID(), zone: zone) // Declared collection conflicts with authoritative route.
        do {
            try await actor.applyRemoteChanges(records: [good, bad], deletedRecordIDs: [], in: .private)
            XCTFail("A per-record decode/routing failure must fail the durable batch")
        } catch { XCTAssertTrue(error is CollectionCodecError) }
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItemRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CollectionCloudRecordState>()), 0)
        try await actor.applyRemoteChanges(records: [good], deletedRecordIDs: [], in: .private)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ItemRecord>()), 1)
    }

    func testFailedLocalApplyPreservesDomainProgressAndOutgoingJournal() async throws {
        let (container, actor, collectionID, zone) = try await setup()
        let remote = item(collectionID: collectionID, zone: zone)
        let outgoing = item(collectionID: collectionID, zone: zone, title: "Pending offline edit")
        try await actor.stageLocalChanges([.save(outgoing)], advancingTo: Data([4]), in: .private)
        try await actor.saveState(Data([5]), for: .private)
        await actor.setPersistenceFailureForTesting { throw CocoaError(.fileWriteOutOfSpace) }
        do { try await actor.applyRemoteChanges(records: [remote], deletedRecordIDs: [], in: .private); XCTFail("Local commit should fail") }
        catch { XCTAssertTrue(error is RepositoryError) }
        await actor.setPersistenceFailureForTesting(nil)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItemRecord>()), 0)
        let restarted = codec(container)
        let pending = try await restarted.pendingLocalChanges(in: .private)
        let state = try await restarted.loadState(for: .private)
        XCTAssertEqual(pending.map(\.recordID), [outgoing.recordID])
        XCTAssertEqual(state, Data([5]))
        try await restarted.applyRemoteChanges(records: [remote], deletedRecordIDs: [], in: .private)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<ItemRecord>()), 1)
    }

    func testUnstagedLocalMutationCannotBeOverwrittenByRemoteSaveOrDelete() async throws {
        let (container, actor, collectionID, zone) = try await setup()
        var local = CollectionPerformanceFixture.items(count: 1, collectionID: collectionID)[0]
        local.title = "Unstaged local edit"
        let context = ModelContext(container)
        context.insert(ItemRecord(from: local))
        context.insert(SyncMutationRecord(collectionID: collectionID, itemID: local.id, recordName: local.id.uuidString, recordType: "CollectionItem"))
        try context.save()
        let incoming = item(local.id, collectionID: collectionID, zone: zone, title: "Remote overwrite", time: 10_000)
        try await actor.applyRemoteChanges(records: [incoming], deletedRecordIDs: [incoming.recordID], in: .private)
        let check = ModelContext(container)
        XCTAssertEqual(try check.fetch(FetchDescriptor<ItemRecord>()).first?.title, "Unstaged local edit")
        XCTAssertEqual(try check.fetchCount(FetchDescriptor<SyncMutationRecord>()), 1)
    }

    func testServerWinningConflictReplacesDomainAndAcknowledgesOnlyThatRecord() async throws {
        let (container, actor, collectionID, zone) = try await setup()
        let attempted = item(collectionID: collectionID, zone: zone, title: "Offline", time: 200)
        let other = item(collectionID: collectionID, zone: zone, title: "Other offline", time: 200)
        try await actor.stageLocalChanges([.save(attempted), .save(other)], advancingTo: nil, in: .private)
        _ = try await actor.record(for: attempted.recordID, in: .private)
        let server = item(UUID(uuidString: attempted.recordID.recordName)!, collectionID: collectionID, zone: zone, title: "Server winner", time: 300)
        try await actor.reconcileFailedSave(attemptedRecord: attempted, serverRecord: server, error: CKError(.serverRecordChanged), in: .private)
        let remaining = try await actor.pendingLocalChanges(in: .private)
        XCTAssertEqual(remaining.map(\.recordID), [other.recordID])
        let check = ModelContext(container)
        XCTAssertEqual(try check.fetch(FetchDescriptor<ItemRecord>()).first?.title, "Server winner")
        XCTAssertEqual(try check.fetchCount(FetchDescriptor<SyncMutationRecord>()), 0)
    }
}
