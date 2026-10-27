import XCTest
import SwiftData
@testable import CollectionManager

@MainActor final class PersistenceSafetyTests: XCTestCase {
    private func makeRepository() throws -> (ModelContainer, ModelContext, CollectionRepository) {
        let schema = Schema(CollectionManagerSchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        return (container, context, CollectionRepository(context: context))
    }

    func testFetchFailureIsNotAnEmptyLibrary() throws {
        let (_, _, repository) = try makeRepository()
        repository.failureInjector = { if case .fetch = $0 { throw CocoaError(.fileReadUnknown) } }
        XCTAssertThrowsError(try repository.collections()) { XCTAssertEqual(($0 as? RepositoryError)?.localizedDescription, RepositoryError.fetchFailed.localizedDescription) }
        repository.failureInjector = nil
        XCTAssertTrue(try repository.collections().isEmpty)
    }

    func testFailedCreationRollsBackLibraryAndJournal() throws {
        let (_, context, repository) = try makeRepository()
        repository.failureInjector = { if case .save = $0 { throw CocoaError(.fileWriteOutOfSpace) } }
        XCTAssertThrowsError(try repository.addCollection(name: "Should roll back", icon: "books.vertical", subtitle: ""))
        repository.failureInjector = nil
        XCTAssertTrue(try repository.collections().isEmpty)
        XCTAssertTrue(try repository.pendingMutations().isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CollectionMemberRecord>()), 0)
    }

    func testItemEventAndOutboxAreAtomicAndFailedDeletePreservesAll() throws {
        let (_, context, repository) = try makeRepository()
        try repository.addCollection(name: "Fixture", icon: "books.vertical", subtitle: "")
        let collection = try XCTUnwrap(repository.collections().first)
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: collection.id)[0]
        XCTAssertTrue(try repository.addItem(item))
        let originalOutbox = try repository.pendingMutations().count
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), 1)
        XCTAssertTrue(try repository.pendingMutations().contains { $0.recordType == "CollectionEvent" })
        repository.failureInjector = { if case .save = $0 { throw CocoaError(.fileWriteOutOfSpace) } }
        XCTAssertThrowsError(try repository.deleteItem(item))
        repository.failureInjector = nil
        XCTAssertNotNil(try repository.item(id: item.id))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), 1)
        XCTAssertEqual(try repository.pendingMutations().count, originalOutbox)
        try repository.deleteItem(item)
        XCTAssertNil(try repository.item(id: item.id))
        XCTAssertTrue(try repository.pendingMutations().contains { $0.recordType == "CollectionEvent" && $0.operation == "delete" })
    }

    func testSettingsUseStoredRoleAndRejectForgedOwner() throws {
        let (_, context, repository) = try makeRepository()
        try repository.addCollection(name: "Fixture", icon: "books.vertical", subtitle: "")
        var collection = try XCTUnwrap(repository.collections().first)
        let member = try XCTUnwrap(context.fetch(FetchDescriptor<CollectionMemberRecord>()).first)
        member.role = .viewer; try context.save()
        collection.role = .owner; collection.name = "Forbidden"
        XCTAssertThrowsError(try repository.updateCollection(collection))
        XCTAssertEqual(try repository.collections().first?.name, "Fixture")
    }

    func testForgedItemCollectionCannotBypassStoredPermission() async throws {
        let (container, context, repository) = try makeRepository()
        try repository.addCollection(name: "Owned", icon: "books.vertical", subtitle: "")
        try repository.addCollection(name: "Shared", icon: "books.vertical", subtitle: "")
        let collections = try repository.collections()
        let owned = try XCTUnwrap(collections.first { $0.name == "Owned" })
        let shared = try XCTUnwrap(collections.first { $0.name == "Shared" })
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: shared.id)[0]
        XCTAssertTrue(try repository.addItem(item))
        let member = try XCTUnwrap(context.fetch(FetchDescriptor<CollectionMemberRecord>()).first { $0.collectionID == shared.id })
        member.role = .viewer; try context.save()
        let forged = CollectionItem(id: item.id, collectionID: owned.id, title: "Forbidden", brand: item.brand, variant: item.variant, itemDescription: item.itemDescription, state: item.state, quantity: item.quantity, barcode: item.barcode, createdAt: item.createdAt, updatedAt: item.updatedAt, consumedAt: item.consumedAt, tags: item.tags, metadata: item.metadata, imageSystemName: item.imageSystemName, imageData: item.imageData, importSourceKey: item.importSourceKey)
        XCTAssertThrowsError(try repository.updateItem(forged))
        XCTAssertThrowsError(try repository.deleteItem(forged))
        let background = CollectionBackgroundRepository(container: container)
        do {
            _ = try await background.deleteItem(id: item.id, collectionID: owned.id)
            XCTFail("Forged collection must be rejected")
        } catch { XCTAssertTrue(error is RepositoryError) }
        XCTAssertEqual(try repository.item(id: item.id)?.title, item.title)
    }

    func testRecoveryExportUsesActualSidecarsAndUniqueDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")
        let members = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        for (index, member) in members.enumerated() { try Data([UInt8(index)]).write(to: member) }
        let first = try PersistentStoreBootstrap.makeSafeExport(from: url, into: directory)
        let second = try PersistentStoreBootstrap.makeSafeExport(from: url, into: directory)
        XCTAssertNotEqual(first, second)
        for member in members {
            XCTAssertEqual(try Data(contentsOf: member), try Data(contentsOf: first.appendingPathComponent(member.lastPathComponent)))
        }
        XCTAssertThrowsError(try PersistentStoreBootstrap.makeSafeExport(from: directory.appendingPathComponent("missing.store"), into: directory))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("CollectionManager-store-") }.count, 2)
    }

    func testCorruptStoreIsPreservedAndClassifiedWithoutFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("corrupt.store")
        let original = Data("This is not a SQLite database".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try PersistentStoreBootstrap.makeContainer(at: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertEqual(PersistentStoreBootstrap.failure(for: denied).phase, .recoverableFailure)
    }
}
