import XCTest
@testable import CollectionManager

@MainActor final class QueryProcessorTests: XCTestCase {
    private func fixture(_ titles: [String]) -> [CollectionItem] {
        var items = CollectionPerformanceFixture.items(count: titles.count)
        for index in titles.indices { items[index].title = titles[index] }
        return items
    }

    private func evaluate(_ items: [CollectionItem], sort: ItemSort = .updatedDescending,
                          fields: [MetadataFieldDefinition] = [], search: String = "",
                          state: ItemState? = nil, brand: String? = nil,
                          locale: Locale = .current) throws -> [String] {
        try ItemQueryProcessor.evaluate(ItemQueryRequest(items: items, searchIndex: ItemSearchIndex(items: items),
            searchText: search, selectedState: state, selectedBrand: brand, sort: sort,
            metadataFields: fields, locale: locale)).map(\.title)
    }

    func testSearchFilterAndNaturalTitleOrderingKeepExistingSemantics() throws {
        var items = fixture(["Item 10", "Item 2", "Café"])
        items[0].brand = "Brand"; items[1].brand = "Brand"; items[2].brand = "brand"
        items[0].state = .stored; items[1].state = .stored; items[2].state = .wanted
        items[1].metadata["example"] = .string("Needle")
        XCTAssertEqual(try evaluate(items, sort: .titleAscending), ["Café", "Item 2", "Item 10"])
        XCTAssertEqual(try evaluate(items, sort: .titleAscending, search: "  ITEM  ", state: .stored, brand: "Brand"), ["Item 2", "Item 10"])
        XCTAssertEqual(try evaluate(items, search: "NEEDLE"), ["Item 2"])
        XCTAssertEqual(try evaluate(items, search: "CAFÉ"), ["Café"])
        XCTAssertEqual(try evaluate(items, search: "cafe"), []) // No new diacritic folding.
        XCTAssertEqual(try evaluate(items, brand: "brand"), ["Café"]) // Brand filter remains exact.
    }

    func testDateTagOrderingRetainsStableEqualDatesAndPutsMissingDatesLast() throws {
        var items = fixture(["Zulu", "Alpha", "Bravo", "Missing Z", "Missing A"])
        items[0].dateTags = ["later": Date(timeIntervalSince1970: 200)]
        items[1].dateTags = ["later": Date(timeIntervalSince1970: 200)]
        items[2].dateTags = ["earlier": Date(timeIntervalSince1970: 100)]
        XCTAssertEqual(try evaluate(items, sort: .dateAscending), ["Bravo", "Zulu", "Alpha", "Missing A", "Missing Z"])
        XCTAssertEqual(try evaluate(items, sort: .dateDescending), ["Zulu", "Alpha", "Bravo", "Missing A", "Missing Z"])
        for index in items.indices { items[index].updatedAt = Date(timeIntervalSince1970: 100) }
        XCTAssertEqual(try evaluate(items), items.map(\.title))
    }

    func testNumberMetadataUsesCapturedLocaleAndAscendingTitleTiesInBothDirections() throws {
        let field = MetadataFieldDefinition(name: "Amount", type: .number)
        var items = fixture(["Zulu", "Alpha", "Bravo", "Missing Z", "Missing A"])
        items[0].metadata[field.storageKey] = .integer(2)
        items[1].metadata[field.storageKey] = .decimal(2)
        items[2].metadata[field.storageKey] = .string("1,5")
        items[3].metadata[field.storageKey] = .string("not a number")
        XCTAssertEqual(try evaluate(items, sort: .metadata(fieldID: field.id, direction: .ascending), fields: [field], locale: Locale(identifier: "de_DE")), ["Bravo", "Alpha", "Zulu", "Missing A", "Missing Z"])
        XCTAssertEqual(try evaluate(items, sort: .metadata(fieldID: field.id, direction: .descending), fields: [field], locale: Locale(identifier: "de_DE")), ["Alpha", "Zulu", "Bravo", "Missing A", "Missing Z"])
    }

    func testDateAndBooleanMetadataCoercionNilAndTieRules() throws {
        let dateField = MetadataFieldDefinition(name: "Date", type: .date)
        let booleanField = MetadataFieldDefinition(name: "Flag", type: .boolean)
        var items = fixture(["Zulu", "Alpha", "Bravo", "Missing Z", "Missing A"])
        items[0].metadata[dateField.storageKey] = .date(Date(timeIntervalSince1970: 200))
        items[1].metadata[dateField.storageKey] = .date(Date(timeIntervalSince1970: 200))
        items[2].metadata[dateField.storageKey] = .date(Date(timeIntervalSince1970: 100))
        items[3].metadata[dateField.storageKey] = .string("2025-01-01") // Date sorting does not parse strings.
        XCTAssertEqual(try evaluate(items, sort: .metadata(fieldID: dateField.id, direction: .descending), fields: [dateField]), ["Alpha", "Zulu", "Bravo", "Missing A", "Missing Z"])
        items[0].metadata[booleanField.storageKey] = .string(" on ")
        items[1].metadata[booleanField.storageKey] = .decimal(-2)
        items[2].metadata[booleanField.storageKey] = .integer(0)
        items[3].metadata[booleanField.storageKey] = .string("unknown")
        XCTAssertEqual(try evaluate(items, sort: .metadata(fieldID: booleanField.id, direction: .ascending), fields: [booleanField]), ["Bravo", "Alpha", "Zulu", "Missing A", "Missing Z"])
        XCTAssertEqual(try evaluate(items, sort: .metadata(fieldID: booleanField.id, direction: .descending), fields: [booleanField]), ["Alpha", "Zulu", "Bravo", "Missing A", "Missing Z"])
    }

    func testTextAndColorMetadataShareNaturalComparisonEmptyAndTieRules() throws {
        for type in [MetadataFieldType.text, .color] {
            let field = MetadataFieldDefinition(name: "Value", type: type)
            var items = fixture(["Zulu", "Alpha", "Bravo", "Missing Z", "Missing A"])
            items[0].metadata[field.storageKey] = .string(" value 10 ")
            items[1].metadata[field.storageKey] = .string("value 10")
            items[2].metadata[field.storageKey] = .string("value 2")
            items[3].metadata[field.storageKey] = .string("   ")
            XCTAssertEqual(try evaluate(items, sort: .metadata(fieldID: field.id, direction: .ascending), fields: [field]), ["Bravo", "Alpha", "Zulu", "Missing A", "Missing Z"])
            XCTAssertEqual(try evaluate(items, sort: .metadata(fieldID: field.id, direction: .descending), fields: [field]), ["Alpha", "Zulu", "Bravo", "Missing A", "Missing Z"])
        }
    }

    func testRemovedMetadataFieldFallsBackToUpdatedDescending() throws {
        let items = fixture(["Oldest", "Middle", "Newest"])
        XCTAssertEqual(try evaluate(items, sort: .metadata(fieldID: UUID(), direction: .ascending)), ["Newest", "Middle", "Oldest"])
    }

    func testPureRequestCanExecuteInDetachedTaskAndCancelledRequestThrows() async throws {
        let items = fixture(["Item 10", "Item 2"])
        let request = ItemQueryRequest(items: items, searchIndex: ItemSearchIndex(items: items), searchText: "item", sort: .titleAscending)
        let result = try await Task.detached { try ItemQueryProcessor.evaluate(request) }.value
        XCTAssertEqual(result.map(\.title), ["Item 2", "Item 10"])
        let cancelled = Task.detached {
            // Wait for the test's explicit cancellation before entering evaluate;
            // this avoids timing-dependent assumptions about fixture size.
            while !Task.isCancelled { await Task.yield() }
            return try ItemQueryProcessor.evaluate(request)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled request must not produce a result") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
