import XCTest
import SwiftData
@testable import CollectionManager

@MainActor final class PersistenceValidationTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, ModelContext, CollectionRepository, CollectionModel) {
        let container = try ModelContainer(for: Schema(CollectionManagerSchemaV1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container), repository = CollectionRepository(context: ModelContext(container))
        try repository.addCollection(name: "Validation", icon: "books.vertical", subtitle: "")
        var collection = try XCTUnwrap(repository.collections().first)
        collection.defaultStatusID = ItemState.stored.rawValue
        try repository.updateCollection(collection)
        return (container, context, repository, collection)
    }

    func testNewItemReviewImportRollsBackWholeBatchAndPreservesDuplicatePolicy() throws {
        let (_, context, repository, collection) = try fixture()
        let before = try repository.pendingMutations().count
        repository.failureInjector = { if case .save = $0 { throw CocoaError(.fileWriteOutOfSpace) } }
        XCTAssertThrowsError(try repository.importNewDrafts([draft("First"), draft("Second")], collectionID: collection.id, allowsDuplicates: true))
        repository.failureInjector = nil
        XCTAssertTrue(try repository.items(in: collection.id).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), 0)
        XCTAssertEqual(try repository.pendingMutations().count, before)
        try repository.importNewDrafts([draft("Same"), draft("Same")], collectionID: collection.id, allowsDuplicates: false)
        XCTAssertEqual(try repository.items(in: collection.id).count, 1)
        try repository.importNewDrafts([draft("Same")], collectionID: collection.id, allowsDuplicates: true)
        XCTAssertEqual(try repository.items(in: collection.id).count, 2)
    }

    private func assertValidation(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let typed = error as? RepositoryError else { return XCTFail("Expected a typed repository error", file: file, line: line) }
            if case .validation = typed {} else { XCTFail("Expected validation failure", file: file, line: line) }
        }
    }

    private func draft(_ title: String, state: ItemState = .wanted, explicit: Bool = true, metadata: [String: MetadataValue] = [:]) -> ImportDraft {
        ImportDraft(title: title, brand: "", variant: "", description: "", state: state, quantity: 1, tags: [], barcode: nil, metadata: metadata, stateWasExplicit: explicit)
    }

    func testNonfiniteCreateDoesNotLoseMetadataOrCreateEventsAndIntent() throws {
        let (_, context, repository, collection) = try fixture()
        let before = try repository.pendingMutations().count
        var item = CollectionPerformanceFixture.items(count: 1, collectionID: collection.id)[0]
        item.metadata["invalid"] = .decimal(.nan)
        assertValidation { _ = try repository.addItem(item) }
        XCTAssertTrue(try repository.items(in: collection.id).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), 0)
        XCTAssertEqual(try repository.pendingMutations().count, before)
    }

    func testNonfiniteUpdatePreservesOriginalFieldsMetadataAndOutbox() throws {
        let (_, context, repository, collection) = try fixture()
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: collection.id)[0]
        XCTAssertTrue(try repository.addItem(item))
        let before = try repository.pendingMutations().count
        let eventCount = try context.fetchCount(FetchDescriptor<EventRecord>())
        var invalid = item; invalid.title = "Must not overwrite"; invalid.metadata["invalid"] = .decimal(.infinity)
        assertValidation { try repository.updateItem(invalid) }
        let retained = try XCTUnwrap(repository.item(id: item.id))
        XCTAssertEqual(retained.title, item.title)
        XCTAssertEqual(retained.metadata, item.metadata)
        XCTAssertEqual(try repository.pendingMutations().count, before)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), eventCount)
    }

    func testImportAndWebBatchesPreflightEveryEntryBeforeAnyWrite() throws {
        let (_, context, repository, collection) = try fixture()
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: collection.id)[0]
        XCTAssertTrue(try repository.addItem(item))
        let before = try repository.pendingMutations().count
        let eventCount = try context.fetchCount(FetchDescriptor<EventRecord>())
        let valid = draft("Must not insert")
        let invalid = draft("Must not overwrite", metadata: ["invalid": .decimal(-.infinity)])
        assertValidation { try repository.importDrafts([(valid, "new"), (invalid, "fixture-0")], collectionID: collection.id) }
        assertValidation { _ = try repository.applyWebDrafts([(valid, "new", true), (invalid, "fixture-0", true)], collectionID: collection.id) }
        XCTAssertEqual(try repository.items(in: collection.id).map(\.title), [item.title])
        XCTAssertEqual(try repository.item(id: item.id)?.metadata, item.metadata)
        XCTAssertEqual(try repository.pendingMutations().count, before)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), eventCount)
    }

    func testAbsentAndInvalidImportStatesUsePersistedDefaultAndExplicitValidStateSurvives() throws {
        let (container, _, repository, collection) = try fixture()
        try repository.importDrafts([
            (draft("Absent", explicit: false), "absent"),
            (draft("Invalid", state: ItemState(rawValue: "removed")), "invalid"),
            (draft("Explicit", state: .wanted), "explicit")
        ], collectionID: collection.id)
        let reopened = CollectionRepository(context: ModelContext(container))
        let states = Dictionary(uniqueKeysWithValues: try reopened.items(in: collection.id).map { ($0.title, $0.state.rawValue) })
        XCTAssertEqual(states["Absent"], "stored")
        XCTAssertEqual(states["Invalid"], "stored")
        XCTAssertEqual(states["Explicit"], "wanted")
        XCTAssertEqual(try reopened.collections().first?.defaultStatusID, "stored")
    }

    func testWebAndDirectCreationNormalizeInvalidStatesWithoutChangingExplicitValidChoice() throws {
        let (_, _, repository, collection) = try fixture()
        var item = CollectionPerformanceFixture.items(count: 1, collectionID: collection.id)[0]
        item.state = ItemState(rawValue: "removed")
        XCTAssertTrue(try repository.addItem(item))
        XCTAssertEqual(try repository.item(id: item.id)?.state, .stored)
        _ = try repository.applyWebDrafts([(draft("Web absent", explicit: false), "web-absent", true), (draft("Web explicit", state: .consumed), "web-explicit", true)], collectionID: collection.id)
        let states = Dictionary(uniqueKeysWithValues: try repository.items(in: collection.id).map { ($0.title, $0.state.rawValue) })
        XCTAssertEqual(states["Web absent"], "stored")
        XCTAssertEqual(states["Web explicit"], "consumed")
    }
}
