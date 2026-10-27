import XCTest
import SwiftData
@testable import CollectionManager

@MainActor final class WebSyncWriteTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, CollectionRepository, CollectionModel) {
        let container = try ModelContainer(for: Schema(CollectionManagerSchemaV1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let repository = CollectionRepository(context: ModelContext(container))
        try repository.addCollection(name: "Web sync", icon: "books.vertical", subtitle: "")
        return (container, repository, try XCTUnwrap(repository.collections().first))
    }

    private func configuration(_ collectionID: UUID) -> WebSyncRecord {
        WebSyncRecord(collectionID: collectionID, urlString: "https://example.invalid/original", tableName: "Original", headers: ["Title"], mapping: [.standard(.title)])
    }

    func testFailedNewConfigurationSaveLeavesNoMetadataFieldsOrConfiguration() throws {
        let (container, repository, collection) = try fixture()
        let baseline = try repository.pendingMutations().count
        let field = MetadataFieldDefinition(name: "Atomic field", type: .text)
        repository.failureInjector = { if case .save = $0 { throw CocoaError(.fileWriteOutOfSpace) } }
        XCTAssertThrowsError(try repository.addWebSync(configuration(collection.id), metadataFieldsToCreate: [field]))
        let reopened = CollectionRepository(context: ModelContext(container))
        XCTAssertTrue(try reopened.webSyncs(for: collection.id).isEmpty)
        XCTAssertFalse(try reopened.metadataFields(for: collection.id).contains { $0.id == field.id })
        XCTAssertEqual(try reopened.pendingMutations().count, baseline)
    }

    func testFailedExistingConfigurationSaveRollsBackValuesFieldsAndIntent() throws {
        let (container, repository, collection) = try fixture()
        let sync = configuration(collection.id)
        try repository.addWebSync(sync)
        let baseline = try repository.pendingMutations().count
        let field = MetadataFieldDefinition(name: "Must roll back", type: .number)
        repository.failureInjector = { if case .save = $0 { throw CocoaError(.fileWriteOutOfSpace) } }
        XCTAssertThrowsError(try repository.updateWebSync(sync, metadataFieldsToCreate: [field]) { value in
            value.urlString = "https://example.invalid/changed"
            value.tableName = "Changed"; value.intervalMinutes = 17
        })
        let reopened = CollectionRepository(context: ModelContext(container))
        let retained = try XCTUnwrap(reopened.webSyncs(for: collection.id).first)
        XCTAssertEqual(retained.urlString, "https://example.invalid/original")
        XCTAssertEqual(retained.tableName, "Original")
        XCTAssertEqual(retained.intervalMinutes, 360)
        XCTAssertFalse(try reopened.metadataFields(for: collection.id).contains { $0.id == field.id })
        XCTAssertEqual(try reopened.pendingMutations().count, baseline)
    }

    func testViewerCannotInvokeMutationClosureOrCreateFields() throws {
        let (container, repository, collection) = try fixture()
        let sync = configuration(collection.id)
        try repository.addWebSync(sync)
        let permissions = ModelContext(container)
        let member = try XCTUnwrap(permissions.fetch(FetchDescriptor<CollectionMemberRecord>()).first)
        member.roleRawValue = "viewer"; try permissions.save()
        let fresh = CollectionRepository(context: ModelContext(container))
        let field = MetadataFieldDefinition(name: "Forbidden", type: .text)
        var closureRan = false
        XCTAssertThrowsError(try fresh.updateWebSync(sync, metadataFieldsToCreate: [field]) { value in
            closureRan = true; value.tableName = "Forbidden"
        })
        XCTAssertFalse(closureRan)
        XCTAssertFalse(try fresh.metadataFields(for: collection.id).contains { $0.id == field.id })
        XCTAssertEqual(try fresh.webSyncs(for: collection.id).first?.tableName, "Original")
    }

    func testInterleavedLaterConfigurationEditRejectsOlderStagedUpdateAtomically() throws {
        let (container, repository, collection) = try fixture()
        let sync = configuration(collection.id)
        try repository.addWebSync(sync)
        let older = CollectionRepository(context: ModelContext(container))
        let later = CollectionRepository(context: ModelContext(container))
        let olderSync = try XCTUnwrap(older.webSyncs(for: collection.id).first)
        let laterSync = try XCTUnwrap(later.webSyncs(for: collection.id).first)
        let field = MetadataFieldDefinition(name: "Older pending field", type: .text)
        older.failureInjector = { point in
            if case .save = point {
                try later.updateWebSync(laterSync) { value in
                    value.urlString = "https://example.invalid/later"
                    value.tableName = "Later manual table"; value.intervalMinutes = 42
                }
            }
        }
        XCTAssertThrowsError(try older.updateWebSync(olderSync, metadataFieldsToCreate: [field]) { value in
            value.urlString = "https://example.invalid/older"
            value.tableName = "Older staged table"; value.intervalMinutes = 7
        }) { error in
            guard let typed = error as? RepositoryError, case .saveFailed = typed else { return XCTFail("Stale operation must report saveFailed") }
        }
        let reopened = CollectionRepository(context: ModelContext(container))
        let retained = try XCTUnwrap(reopened.webSyncs(for: collection.id).first)
        XCTAssertEqual(retained.id, sync.id)
        XCTAssertEqual(retained.urlString, "https://example.invalid/later")
        XCTAssertEqual(retained.tableName, "Later manual table")
        XCTAssertEqual(retained.intervalMinutes, 42)
        XCTAssertFalse(try reopened.metadataFields(for: collection.id).contains { $0.id == field.id })
    }

    func testSuccessfulConfigurationSaveCommitsItsNewFieldDefinitionsTogether() throws {
        let (container, repository, collection) = try fixture()
        let sync = configuration(collection.id)
        let first = MetadataFieldDefinition(name: "First", type: .text)
        try repository.addWebSync(sync, metadataFieldsToCreate: [first])
        let second = MetadataFieldDefinition(name: "Second", type: .date)
        try repository.updateWebSync(sync, metadataFieldsToCreate: [second]) { $0.tableName = "Updated" }
        let reopened = CollectionRepository(context: ModelContext(container))
        XCTAssertEqual(try reopened.webSyncs(for: collection.id).first?.tableName, "Updated")
        XCTAssertEqual(Set(try reopened.metadataFields(for: collection.id).map(\.id)), [first.id, second.id])
    }
}
