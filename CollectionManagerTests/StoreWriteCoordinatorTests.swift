import XCTest
import SwiftData
@testable import CollectionManager

@MainActor final class StoreWriteCoordinatorTests: XCTestCase {
    private func memoryContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(CollectionManagerSchemaV1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    func testStaleSameCollectionCommitIsRejectedBeforeSaveButOtherScopeCanCommit() throws {
        let coordinator = StoreWriteCoordinator.forContainer(try memoryContainer())
        let first = UUID(), second = UUID(), captured = coordinator.snapshot()
        _ = try coordinator.commit(expected: captured, changedCollections: [first]) {}
        var staleClosureExecuted = false
        XCTAssertThrowsError(try coordinator.commit(expected: captured, changedCollections: [first]) { staleClosureExecuted = true })
        XCTAssertFalse(staleClosureExecuted)
        _ = try coordinator.commit(expected: captured, changedCollections: [second]) {}
        XCTAssertEqual(coordinator.snapshot()[first], 1)
        XCTAssertEqual(coordinator.snapshot()[second], 1)
    }

    func testFailedSaveDoesNotAdvanceRevisionsAndCanRetryOriginalSnapshot() throws {
        let coordinator = StoreWriteCoordinator.forContainer(try memoryContainer())
        let collection = UUID(), captured = coordinator.snapshot()
        XCTAssertThrowsError(try coordinator.commit(expected: captured, changedCollections: [collection]) { throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertEqual(coordinator.snapshot(), captured)
        let committed = try coordinator.commit(expected: captured, changedCollections: [collection]) {}
        XCTAssertEqual(committed[collection], 1)
    }

    func testBusySaveGateFailsFastWhileRevisionSnapshotsRemainReadable() throws {
        let coordinator = StoreWriteCoordinator.forContainer(try memoryContainer())
        let first = UUID(), second = UUID(), captured = coordinator.snapshot()
        _ = try coordinator.commit(expected: captured, changedCollections: [first]) {
            // This nested snapshot would deadlock if disk save held the same
            // mutex as the revision dictionary. The inner commit must fail fast.
            XCTAssertEqual(coordinator.snapshot(), captured)
            XCTAssertThrowsError(try coordinator.commit(expected: captured, changedCollections: [second]) { XCTFail("Busy inner save must not run") })
        }
        XCTAssertEqual(coordinator.snapshot()[first], 1)
        XCTAssertNil(coordinator.snapshot()[second])
    }

    func testSameDiskURLSharesFenceAcrossContainersAndMemoryStoresStayIsolated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Fixture.store")
        let first = try ModelContainer(for: Schema(CollectionManagerSchemaV1.models), configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let second = try ModelContainer(for: Schema(CollectionManagerSchemaV1.models), configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        XCTAssertTrue(StoreWriteCoordinator.forContainer(first) === StoreWriteCoordinator.forContainer(second))
        let memory1 = try memoryContainer(), memory2 = try memoryContainer()
        XCTAssertFalse(StoreWriteCoordinator.forContainer(memory1) === StoreWriteCoordinator.forContainer(memory2))
        XCTAssertTrue(StoreWriteCoordinator.forContainer(memory1) === StoreWriteCoordinator.forContainer(memory1))
    }

    func testOnlyDomainMembershipAndWebConfigurationAdvanceCollectionScope() throws {
        let container = try memoryContainer()
        let fixture = ModelContext(container), first = UUID(), second = UUID()
        fixture.insert(SyncMutationRecord(collectionID: first, recordName: first.uuidString, recordType: "Collection"))
        fixture.insert(CloudSyncStateRecord(collectionID: first))
        XCTAssertTrue(StoreWriteCoordinator.changedCollections(in: fixture).isEmpty)
        fixture.insert(CollectionMemberRecord(collectionID: first, participantID: "cloud", role: .viewer))
        fixture.insert(WebSyncRecord(collectionID: second, urlString: "https://example.invalid", tableName: "Fixture", headers: [], mapping: []))
        XCTAssertEqual(StoreWriteCoordinator.changedCollections(in: fixture), [first, second])
    }
}
