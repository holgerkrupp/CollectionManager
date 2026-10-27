import XCTest
@testable import CollectionManager

@MainActor final class TableSortTests: XCTestCase {
    private func fixture() -> [CollectionItem] {
        var items = CollectionPerformanceFixture.items(count: 3)
        items[0].title = "Zulu"; items[0].quantity = 3
        items[1].title = "Alpha"; items[1].quantity = 3
        items[2].title = "Bravo"; items[2].quantity = 1
        return items
    }

    func testTitleHeaderOrderAndReverseKeepOriginalItemIdentityAndPayload() async throws {
        var items = fixture()
        items[0].imageData = Data([1, 2, 3])
        items[0].metadata["retained"] = .string("Keep selected row payload")
        let snapshot = items
        let ascending = try await Task.detached {
            try CollectionTableSort.sorted(snapshot, using: [KeyPathComparator(\.title)])
        }.value
        let descending = try CollectionTableSort.sorted(items, using: [KeyPathComparator(\.title, order: .reverse)])
        XCTAssertEqual(ascending.map(\.id), [items[1].id, items[2].id, items[0].id])
        XCTAssertEqual(descending.map(\.id), [items[0].id, items[2].id, items[1].id])
        XCTAssertEqual(descending.first, items[0])
        XCTAssertEqual(snapshot.map(\.title), ["Zulu", "Alpha", "Bravo"])
    }

    func testQuantityHeaderPreservesStableTiesAndUsesSecondaryComparatorWhenRequested() throws {
        let items = fixture()
        let ascending = try CollectionTableSort.sorted(items, using: [KeyPathComparator(\.quantity)])
        let descending = try CollectionTableSort.sorted(items, using: [KeyPathComparator(\.quantity, order: .reverse)])
        let secondary = try CollectionTableSort.sorted(items, using: [KeyPathComparator(\.quantity, order: .reverse), KeyPathComparator(\.title)])
        XCTAssertEqual(ascending.map(\.id), [items[2].id, items[0].id, items[1].id])
        XCTAssertEqual(descending.map(\.id), [items[0].id, items[1].id, items[2].id])
        XCTAssertEqual(secondary.map(\.id), [items[1].id, items[0].id, items[2].id])
        XCTAssertEqual(Set(secondary.map(\.id)), Set(items.map(\.id)))
    }

    func testObsoleteCacheNeverReplacesCurrentStoreRowsAfterScopeRevisionOrSortChanges() {
        let old = fixture()
        var current = CollectionPerformanceFixture.items(count: 1, collectionID: UUID())
        current[0].title = "Current scope"
        let collectionID = old[0].collectionID
        let order = [KeyPathComparator<CollectionItem>(\.title)]
        let identity = CollectionTableSortIdentity(visibleItemsRevision: 1, sortOrder: order, usesColumnSort: true, collectionID: collectionID)
        let cache = CollectionTableSortCache(identity: identity, sortedRows: old)
        XCTAssertEqual(cache.rows(for: identity, fallback: current), old)
        let obsoleteIdentities = [
            CollectionTableSortIdentity(visibleItemsRevision: 2, sortOrder: order, usesColumnSort: true, collectionID: collectionID),
            CollectionTableSortIdentity(visibleItemsRevision: 1, sortOrder: [KeyPathComparator(\.title, order: .reverse)], usesColumnSort: true, collectionID: collectionID),
            CollectionTableSortIdentity(visibleItemsRevision: 1, sortOrder: order, usesColumnSort: false, collectionID: collectionID),
            CollectionTableSortIdentity(visibleItemsRevision: 1, sortOrder: order, usesColumnSort: true, collectionID: current[0].collectionID)
        ]
        for currentIdentity in obsoleteIdentities {
            XCTAssertEqual(cache.rows(for: currentIdentity, fallback: current), current)
        }
    }

    func testCanceledHeaderSortCannotReturnRowsForPublication() async {
        let items = fixture()
        let cancelled = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try CollectionTableSort.sorted(items, using: [KeyPathComparator(\.quantity)])
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Canceled header sort must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
