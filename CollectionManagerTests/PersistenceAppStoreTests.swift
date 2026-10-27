import XCTest
import SwiftData
import CloudKit
@testable import CollectionManager

@MainActor final class PersistenceAppStoreTests: XCTestCase {
    func testUnopenedStoreCannotServiceBackgroundIntent() {
        XCTAssertThrowsError(try AppStore().beginIntentOperation())
    }

    func testOpenStoreObservesActorImportAndCanRestoreAnEarlierValue() async throws {
        let container = try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = AppStore()
        store.configure(context: container.mainContext, container: container)
        XCTAssertTrue(store.addCollection(name: "Initial", icon: "books.vertical", subtitle: ""))
        let collection = try XCTUnwrap(store.collections.first)
        let codec = CollectionRecordCodec(modelContainer: container, containerIdentifier: "iCloud.example.cache-test", environment: .development, accountPartitionIdentifier: "synthetic-account")
        try await codec.beginHandoff()
        _ = try await codec.stageRepositoryMutations()
        let changes = try await codec.pendingLocalChanges(in: .private)
        let id = try XCTUnwrap(changes.first?.recordID)
        let pending = try await codec.record(for: id, in: .private)
        let root = try XCTUnwrap(pending)
        try await codec.acknowledgeSentChanges(savedRecords: [root], deletedRecordIDs: [], in: .private)
        root["name"] = "Remote"; root["updatedAt"] = Date().addingTimeInterval(100)
        try await codec.applyRemoteChanges(records: [root], deletedRecordIDs: [], in: .private)
        store.loadCollections()
        XCTAssertEqual(store.collections.first?.name, "Remote")
        var restored = try XCTUnwrap(store.collections.first)
        XCTAssertEqual(restored.id, collection.id)
        restored.name = "Initial"
        XCTAssertTrue(store.updateCollection(restored))
        let persisted = try ModelContext(container).fetch(FetchDescriptor<CollectionRecord>()).first
        XCTAssertEqual(persisted?.name, "Initial")
    }

    func testFailedRatingSaveReturnsFailureWithoutOptimisticRating() throws {
        let container = try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var failSave = false
        let store = AppStore()
        store.configure(context: ModelContext(container), container: container, failureInjector: { if failSave, case .save = $0 { throw CocoaError(.fileWriteOutOfSpace) } })
        XCTAssertTrue(store.addCollection(name: "Ratings", icon: "books.vertical", subtitle: ""))
        let item = try XCTUnwrap(store.addItem(title: "Fixture", brand: "", variant: "", description: "", state: .wanted, quantity: 1, tags: []))
        failSave = true
        XCTAssertFalse(store.setRating(3, for: item))
        XCTAssertTrue(try XCTUnwrap(store.item(id: item.id)).ratings.isEmpty)
        XCTAssertNotNil(store.persistenceError)
    }

    func testFailedSaveReachesStoreAndCannotLookLikeSuccessfulAddition() throws {
        let schema = Schema(CollectionManagerSchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = AppStore()
        store.configure(context: ModelContext(container), container: container, failureInjector: {
            if case .save = $0 { throw CocoaError(.fileWriteOutOfSpace) }
        })
        try store.beginIntentOperation()
        store.addCollection(name: "Rejected", icon: "books.vertical", subtitle: "")
        XCTAssertNotNil(store.persistenceError)
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertThrowsError(try store.checkIntentOperation())
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<SyncMutationRecord>()), 0)
    }

    func testFailedRefreshRetainsLastVisibleLibraryAndExposesFailure() throws {
        let schema = Schema(CollectionManagerSchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var shouldFail = false
        let store = AppStore()
        store.configure(context: ModelContext(container), container: container, failureInjector: {
            if shouldFail, case .fetch = $0 { throw CocoaError(.fileReadUnknown) }
        })
        store.addCollection(name: "Preserved", icon: "books.vertical", subtitle: "")
        XCTAssertEqual(store.collections.count, 1)
        shouldFail = true
        store.loadCollections()
        XCTAssertEqual(store.collections.first?.name, "Preserved")
        XCTAssertNotNil(store.persistenceError)
        XCTAssertFalse(store.isLoading)
    }
}
