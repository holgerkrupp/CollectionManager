import XCTest
import SwiftData
@testable import CollectionManager

@MainActor final class PersistenceMigrationTests: XCTestCase {
    func testAuditedV1FixtureOpensWithoutDataLossAndExportsRecoverably() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CollectionManager", withExtension: "store"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("CollectionManager.store")
        try FileManager.default.copyItem(at: source, to: store)
        try verifyFixture(at: store)
        let exported = try PersistentStoreBootstrap.makeSafeExport(from: store, into: directory)
        try verifyFixture(at: exported.appendingPathComponent(store.lastPathComponent))
    }

    private func verifyFixture(at url: URL) throws {
        let container = try PersistentStoreBootstrap.makeContainer(at: url)
        let context = ModelContext(container)
        let collection = try XCTUnwrap(context.fetch(FetchDescriptor<CollectionRecord>()).first)
        XCTAssertEqual(collection.name, "Audited V1 fixture")
        let settings = try JSONDecoder().decode(CollectionSettingsPayload.self, from: Data(collection.settingsJSON.utf8))
        XCTAssertTrue(settings.barcodeRequired)
        XCTAssertEqual(settings.defaultStatusID, "stored")
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<ItemRecord>()).first)
        XCTAssertEqual(item.imageData, Data([1,2,3,4]))
        XCTAssertTrue(item.metadataJSON.contains("retained"))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CollectionMemberRecord>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ItemRatingRecord>()).first?.value, 4)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ItemCommentRecord>()).first?.text, "Retained comment")
        XCTAssertEqual(try context.fetch(FetchDescriptor<EventRecord>()).first?.note, "Retained event")
        XCTAssertEqual(try context.fetch(FetchDescriptor<WebSyncRecord>()).first?.urlString, "https://example.invalid/fixture")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SyncMutationRecord>()).first?.operation, "delete")
        XCTAssertEqual(try context.fetch(FetchDescriptor<CloudSyncStateRecord>()).first?.privateChangeTokenData, Data([5,6]))
    }
}
