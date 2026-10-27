import XCTest
import SwiftData
@testable import CollectionManager

@MainActor final class CollectionSettingsPersistenceTests: XCTestCase {
    func testReopenRetainsRulesAndRemovingDefaultFallsBackDeterministically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.store")
        try writeSettings(at: url)
        let container = try PersistentStoreBootstrap.makeContainer(at: url)
        let repository = CollectionRepository(context: ModelContext(container))
        var collection = try XCTUnwrap(repository.collections().first)
        XCTAssertTrue(collection.barcodeRequired)
        XCTAssertEqual(collection.defaultStatusID, "stored")
        collection.statuses.removeAll { $0.id == "stored" }
        try repository.updateCollection(collection)
        let updated = try XCTUnwrap(repository.collections().first)
        XCTAssertEqual(updated.defaultStatusID, updated.statuses.first?.id)
        let stored = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<CollectionRecord>()).first)
        let cloudPayload = try JSONDecoder().decode(CollectionSettingsPayload.self, from: Data(stored.settingsJSON.utf8))
        XCTAssertEqual(cloudPayload.defaultStatusID, updated.defaultStatusID)
        XCTAssertTrue(cloudPayload.barcodeRequired)
    }

    func testSettingsRoundTripThroughActualRootRecordsBetweenStores() async throws {
        let ownerContainer = try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let owner = CollectionRepository(context: ModelContext(ownerContainer))
        try owner.addCollection(name: "Shared rules", icon: "books.vertical", subtitle: "")
        var collection = try XCTUnwrap(owner.collections().first)
        collection.defaultStatusID = "consumed"; collection.barcodeRequired = true
        try owner.updateCollection(collection)
        let ownerCodec = CollectionRecordCodec(modelContainer: ownerContainer, containerIdentifier: "iCloud.example.settings", environment: .development, accountPartitionIdentifier: "synthetic-account")
        try await ownerCodec.beginHandoff()
        let plans = try await ownerCodec.sharePlans()
        let root = try XCTUnwrap(plans.first?.rootRecord)
        let receiverContainer = try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let receiverCodec = CollectionRecordCodec(modelContainer: receiverContainer, containerIdentifier: "iCloud.example.settings", environment: .development, accountPartitionIdentifier: "synthetic-account")
        try await receiverCodec.beginHandoff()
        try await receiverCodec.registerCollection(collectionID: collection.id, zoneID: root.recordID.zoneID, scope: .private, role: .owner)
        try await receiverCodec.applyRemoteChanges(records: [root], deletedRecordIDs: [], in: .private)
        let receiver = CollectionRepository(context: ModelContext(receiverContainer))
        let received = try XCTUnwrap(receiver.collections().first)
        XCTAssertEqual(received.defaultStatusID, "consumed")
        XCTAssertTrue(received.barcodeRequired)
        XCTAssertTrue(try receiver.pendingMutations().isEmpty)
    }

    private func writeSettings(at url: URL) throws {
        let container = try PersistentStoreBootstrap.makeContainer(at: url)
        let repository = CollectionRepository(context: ModelContext(container))
        try repository.addCollection(name: "Rules", icon: "books.vertical", subtitle: "")
        var collection = try XCTUnwrap(repository.collections().first)
        collection.defaultStatusID = "stored"; collection.barcodeRequired = true
        try repository.updateCollection(collection)
    }

    func testStoredBarcodeRuleProtectsDirectCSVAndBackgroundWebWritesAtomically() throws {
        let container = try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let repository = CollectionRepository(context: ModelContext(container))
        try repository.addCollection(name: "Rules", icon: "books.vertical", subtitle: "")
        var collection = try XCTUnwrap(repository.collections().first)
        collection.barcodeRequired = true
        try repository.updateCollection(collection)
        let originalOutboxCount = try repository.pendingMutations().count
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: collection.id)[0]
        XCTAssertThrowsError(try repository.addItem(item))
        let invalid = ImportDraft(title: "Invalid", brand: "", variant: "", description: "", state: .wanted, quantity: 1, tags: [], barcode: nil)
        var valid = invalid; valid.title = "Valid"; valid.barcode = Barcode(rawValue: "036000291452")
        XCTAssertThrowsError(try repository.importDrafts([(valid, "valid"), (invalid, "invalid")], collectionID: collection.id))
        XCTAssertThrowsError(try repository.applyWebDrafts([(valid, "valid", true), (invalid, "invalid", true)], collectionID: collection.id))
        XCTAssertTrue(try repository.items(in: collection.id).isEmpty)
        XCTAssertEqual(try repository.pendingMutations().count, originalOutboxCount)
    }
}
