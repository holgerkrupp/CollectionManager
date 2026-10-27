import XCTest
@testable import CollectionManager

@MainActor final class ItemDerivedStateTests: XCTestCase {
    func testDeterministicFixturePreservesBrandOrderingAndOnlyNamedStateCounts() throws {
        let items = CollectionPerformanceFixture.items(count: 12)
        let derived = try ItemDerivedState.prepare(items: items)
        XCTAssertEqual(derived.brands, ["Brand 0", "Brand 1", "Brand 10", "Brand 11", "Brand 2", "Brand 3", "Brand 4", "Brand 5", "Brand 6", "Brand 7", "Brand 8", "Brand 9"])
        XCTAssertEqual(derived.stats.stored, 2)
        XCTAssertEqual(derived.stats.consumed, 2)
        XCTAssertEqual(derived.stats.wanted, 2)
        XCTAssertFalse(derived.hasDateTags)
        XCTAssertTrue(derived.searchIndex.matches(itemID: items[10].id, normalizedQuery: "fixture item 10"))
    }

    func testEmptyBrandsAreExcludedWithoutTrimmingOrCaseFoldingAndOnlyDateTagsSetFlag() throws {
        var items = CollectionPerformanceFixture.items(count: 5)
        for (index, brand) in ["", " ", "Alpha", "alpha", "Alpha"].enumerated() { items[index].brand = brand }
        items[0].metadata = ["date": .date(Date(timeIntervalSince1970: 100))]
        let withoutTags = try ItemDerivedState.prepare(items: items)
        XCTAssertEqual(withoutTags.brands, [" ", "Alpha", "alpha"])
        XCTAssertFalse(withoutTags.hasDateTags)
        items[4].dateTags = ["stored-date": Date(timeIntervalSince1970: 100)]
        XCTAssertTrue(try ItemDerivedState.prepare(items: items).hasDateTags)
        let empty = try ItemDerivedState.prepare(items: [])
        XCTAssertTrue(empty.brands.isEmpty)
        XCTAssertFalse(empty.hasDateTags)
        XCTAssertEqual(empty.stats.stored + empty.stats.consumed + empty.stats.wanted, 0)
    }

    func testPreparedIndexRetainsCanonicalAndLocaleFormattedNumbers() throws {
        var item = CollectionPerformanceFixture.items(count: 1)[0]
        item.metadata = ["integer": .integer(1000), "decimal": .decimal(1.5)]
        let derived = try ItemDerivedState.prepare(items: [item], locale: Locale(identifier: "de_DE"))
        for query in ["1000", "1.000", "1.5", "1,5"] {
            XCTAssertTrue(derived.searchIndex.matches(itemID: item.id, normalizedQuery: query), query)
        }
    }

    func testCancelledPreparationDoesNotReturnPartiallyPreparedState() async {
        let items = CollectionPerformanceFixture.items(count: 12)
        let cancelled = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try ItemDerivedState.prepare(items: items)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Canceled preparation must not publish derived values") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAppStorePublishesLatestItemsAndCurrentQueryAfterSupersededPreparation() async throws {
        let store = AppStore()
        let oldID = UUID(), latestID = UUID()
        store.selectedCollection = CollectionModel(id: oldID, name: "Old", icon: "books.vertical", subtitle: "")
        store.items = CollectionPerformanceFixture.items(count: 25_000, collectionID: oldID)
        store.searchText = "old query"
        store.selectedCollection = CollectionModel(id: latestID, name: "Latest", icon: "books.vertical", subtitle: "")
        var latest = CollectionPerformanceFixture.items(count: 3, collectionID: latestID)
        latest[0].title = "Needle 10"; latest[1].title = "Needle 2"; latest[2].title = "Other"
        for index in latest.indices { latest[index].state = .stored; latest[index].brand = "New brand" }
        latest[2].brand = "Other brand"
        store.items = latest
        store.searchText = "NEEDLE"
        store.selectedState = .stored
        store.selectedBrand = "New brand"
        store.itemSort = .titleAscending
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if store.visibleItems.map(\.title) == ["Needle 2", "Needle 10"],
               store.brands == ["New brand", "Other brand"], store.stats.stored == 3 { break }
            await Task.yield()
        }
        XCTAssertEqual(store.visibleItems.map(\.title), ["Needle 2", "Needle 10"])
        XCTAssertTrue(store.visibleItems.allSatisfy { $0.collectionID == latestID })
        XCTAssertEqual(store.brands, ["New brand", "Other brand"])
        XCTAssertEqual(store.stats.stored, 3)
        XCTAssertEqual(store.stats.consumed, 0)
        XCTAssertEqual(store.stats.wanted, 0)
        XCTAssertFalse(store.hasDateTags)
        store.items = []
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertTrue(store.brands.isEmpty)
        XCTAssertEqual(store.stats.stored + store.stats.consumed + store.stats.wanted, 0)
        for _ in 0..<32 { await Task.yield() }
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertTrue(store.brands.isEmpty)
        XCTAssertFalse(store.hasDateTags)
    }
}
