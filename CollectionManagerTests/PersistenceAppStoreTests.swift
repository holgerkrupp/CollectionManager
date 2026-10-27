import XCTest
import SwiftData
@testable import CollectionManager

@MainActor final class PersistenceAppStoreTests: XCTestCase {
    func testUnopenedStoreCannotServiceBackgroundIntent() {
        XCTAssertThrowsError(try AppStore().beginIntentOperation())
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
