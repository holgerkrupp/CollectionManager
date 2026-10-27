import XCTest
import SwiftData
@testable import CollectionManager

@MainActor final class PerformanceSearchTests: XCTestCase {
    func testIndexedSearchPreservesExistingFieldsAndNormalization() {
        let id = UUID()
        var items = CollectionPerformanceFixture.items(count: 2, collectionID: id)
        items[0].title = "Café TITLE"
        items[0].variant = "Special variant"
        items[0].itemDescription = "Description value"
        items[0].tags = ["Special-tag"]
        items[0].barcode = Barcode(rawValue: "036000291452")
        items[0].metadata = ["example": .string("Metadata needle")]
        let index = ItemSearchIndex(items: items)
        for rawQuery in ["  TITLE  ", "café", "variant", "description", "special-tag", "0036000291452", "metadata needle", "no match", ""] {
            let query = ItemSearchIndex.normalizedQuery(rawQuery)
            let expected = items.filter { item in
                let text = ([item.title, item.brand, item.variant, item.itemDescription, item.barcode?.value ?? ""] + item.tags + item.metadata.values.map(\.displayValue)).joined(separator: " ").lowercased()
                return query.isEmpty || text.contains(query)
            }.map(\.id)
            XCTAssertEqual(items.filter { index.matches(itemID: $0.id, normalizedQuery: query) }.map(\.id), expected)
        }
    }

    func testLocalizedNumericDisplayKeepsCanonicalNumericSearch() {
        var item = CollectionPerformanceFixture.items(count: 1, collectionID: UUID())[0]
        item.metadata = ["count": .integer(1234), "price": .decimal(5678.5)]
        let german = ItemSearchIndex.searchableText(for: item, locale: Locale(identifier: "de_DE"))
        for query in ["1.234", "5.678,5", "1234", "5678.5"] { XCTAssertTrue(german.contains(query)) }
        let index = ItemSearchIndex(items: [item])
        XCTAssertTrue(index.matches(itemID: item.id, normalizedQuery: "1234"))
        XCTAssertTrue(index.matches(itemID: item.id, normalizedQuery: "5678.5"))
    }

    func testRebuildRemovesDeletedRowsAndUpdatesChangedMetadata() {
        let id = UUID()
        var items = CollectionPerformanceFixture.items(count: 2, collectionID: id)
        var index = ItemSearchIndex(items: items)
        let removedID = items.removeLast().id
        items[0].metadata = ["test": .string("Changed metadata")]
        index.rebuild(items: items)
        XCTAssertFalse(index.matches(itemID: removedID, normalizedQuery: ""))
        XCTAssertTrue(index.matches(itemID: items[0].id, normalizedQuery: "changed metadata"))
        XCTAssertFalse(index.matches(itemID: items[0].id, normalizedQuery: "custom.fixtureindex"))
    }

    /// Reports wall-clock host pipeline work; this is not a UI/frame or real
    /// CloudKit benchmark. Use -only-testing to repeat it without other suites.
    func testMeasuredHostBaseline() async throws {
        for count in CollectionPerformanceFixture.sizes {
            let id = UUID()
            var fixtureTimes: [Double] = []
            var items: [CollectionItem] = []
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                items = CollectionPerformanceFixture.items(count: count, collectionID: id)
                fixtureTimes.append(milliseconds(since: start))
                XCTAssertEqual(items.count, count)
            }
            let indexStart = ProcessInfo.processInfo.systemUptime
            let index = ItemSearchIndex(items: items)
            let indexMS = milliseconds(since: indexStart)
            var legacyTimes: [Double] = [], indexedTimes: [Double] = [], filterTimes: [Double] = [], sortTimes: [Double] = []
            for _ in 0..<7 {
                var start = ProcessInfo.processInfo.systemUptime
                let legacy = items.filter { ItemSearchIndex.searchableText(for: $0).contains("group-17") }
                legacyTimes.append(milliseconds(since: start))
                start = ProcessInfo.processInfo.systemUptime
                let indexed = items.filter { index.matches(itemID: $0.id, normalizedQuery: "group-17") }
                indexedTimes.append(milliseconds(since: start))
                XCTAssertEqual(indexed.map(\.id), legacy.map(\.id))
                start = ProcessInfo.processInfo.systemUptime
                let filtered = items.filter { $0.state == .stored && $0.brand == "Brand 2" }
                filterTimes.append(milliseconds(since: start))
                XCTAssertLessThanOrEqual(filtered.count, count)
                start = ProcessInfo.processInfo.systemUptime
                let sorted = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                sortTimes.append(milliseconds(since: start))
                XCTAssertEqual(sorted.count, count)
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CM-performance-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("fixture.store")
            let seedStart = ProcessInfo.processInfo.systemUptime
            try seed(items, at: url)
            let seedMS = milliseconds(since: seedStart)
            var reopenTimes: [Double] = [], readTimes: [Double] = []
            for _ in 0..<3 {
                let start = ProcessInfo.processInfo.systemUptime
                let schema = Schema(CollectionManagerSchemaV1.models)
                let container = try ModelContainer(for: schema, migrationPlan: CollectionManagerMigrationPlan.self,
                                                   configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
                reopenTimes.append(milliseconds(since: start))
                let readStart = ProcessInfo.processInfo.systemUptime
                let loaded = try await CollectionBackgroundRepository(container: container).items(in: id)
                readTimes.append(milliseconds(since: readStart))
                XCTAssertEqual(loaded.count, count)
                XCTAssertEqual(Set(loaded.map(\.id)), Set(items.map(\.id)))
            }
            let report: [String: Any] = [
                "items": count, "fixture_ms": summary(fixtureTimes), "index_build_ms": indexMS,
                "legacy_search_ms": summary(legacyTimes), "indexed_search_ms": summary(indexedTimes),
                "filter_ms": summary(filterTimes), "title_sort_ms": summary(sortTimes),
                "store_seed_ms": seedMS, "container_reopen_ms": summary(reopenTimes),
                "repository_fetch_decode_ms": summary(readTimes)
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("CM_HOST_BASELINE \(String(decoding: data, as: UTF8.self))")
        }
    }

    private func seed(_ items: [CollectionItem], at url: URL) throws {
        let schema = Schema(CollectionManagerSchemaV1.models)
        let container = try ModelContainer(for: schema, migrationPlan: CollectionManagerMigrationPlan.self,
                                           configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for item in items { context.insert(ItemRecord(from: item)) }
        try context.save()
    }

    private func milliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    private func summary(_ times: [Double]) -> [String: Double] {
        let sorted = times.sorted()
        return ["median": sorted[sorted.count / 2], "p95": sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]]
    }
}
