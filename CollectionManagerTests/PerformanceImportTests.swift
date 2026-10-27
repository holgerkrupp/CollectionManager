import XCTest
import SwiftData
@testable import CollectionManager

/// Exercises CSV parse/mapping and the actual atomic import/event/outbox path.
/// These host timings exclude UI, photos and CloudKit network requests.
@MainActor final class PerformanceImportTests: XCTestCase {
    func testMeasuredCSVRepositoryImport() throws {
        for count in CollectionPerformanceFixture.sizes {
            let report = try autoreleasepool { try measure(count: count) }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("CM_IMPORT_BASELINE \(String(decoding: data, as: UTF8.self))")
        }
    }

    private func measure(count: Int) throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CM-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try PersistentStoreBootstrap.makeContainer(at: directory.appendingPathComponent("Import.store"))
        let context = ModelContext(container)
        let repository = CollectionRepository(context: context)
        try repository.addCollection(name: "CSV measurement", icon: "books.vertical", subtitle: "")
        var collection = try XCTUnwrap(repository.collections().first)
        let price = MetadataFieldDefinition(name: "Price", type: .number)
        collection.metadataFields = [price]
        try repository.updateCollection(collection)
        let pendingBefore = try context.fetchCount(FetchDescriptor<SyncMutationRecord>())
        let csv = "Title,Brand,Quantity,Price,Tags\r\n" + (0..<count).map {
            "Import fixture \($0),Brand \($0 % 37),2,\($0).5,fixture;group-\($0 % 25)"
        }.joined(separator: "\r\n")
        let data = Data(csv.utf8)
        let start = ProcessInfo.processInfo.systemUptime
        let importer = CollectionImporter()
        let table = try importer.parseTable(data)
        let parsed = milliseconds(since: start)
        let preparation = importer.prepareImport(from: table,
            mapping: [.standard(.title), .standard(.brand), .standard(.quantity), .existingMetadata(price.id), .standard(.tags)],
            existingMetadataFields: [price], validStatusIDs: Set(collection.statuses.map(\.id)))
        let mapped = milliseconds(since: start)
        let importStart = ProcessInfo.processInfo.systemUptime
        try repository.importNewDrafts(preparation.drafts, collectionID: collection.id, allowsDuplicates: false)
        let imported = milliseconds(since: importStart)
        let total = milliseconds(since: start)
        let id = collection.id
        let itemCount = try context.fetchCount(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == id }))
        let eventCount = try context.fetchCount(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == id }))
        let pending = try context.fetchCount(FetchDescriptor<SyncMutationRecord>()) - pendingBefore
        XCTAssertEqual(itemCount, count)
        XCTAssertEqual(eventCount, count * 2)
        XCTAssertEqual(pending, count * 3)
        return ["items": count, "csv_bytes": data.count, "parse_ms": parsed,
                "mapping_ms": mapped - parsed, "atomic_import_ms": imported,
                "total_parse_mapping_import_ms": total,
                "persisted_items": itemCount, "persisted_events": eventCount, "durable_outgoing_intents": pending]
    }

    private func milliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }
}
