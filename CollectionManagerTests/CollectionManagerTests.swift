import XCTest

final class CollectionManagerTests: XCTestCase {
    func testBarcodeNormalizationAndCheckDigit() {
        XCTAssertEqual(Barcode(rawValue: "036000291452")?.value, "0036000291452")
        XCTAssertNil(Barcode(rawValue: "036000291453"))
    }

    func testPerformanceFixtureIsDeterministicInShape() {
        let collectionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let items = CollectionPerformanceFixture.items(count: 1_000, collectionID: collectionID)
        XCTAssertEqual(items.count, 1_000)
        XCTAssertEqual(items.first?.collectionID, collectionID)
        XCTAssertEqual(items.first?.title, "Fixture item 0")
        XCTAssertEqual(items.last?.title, "Fixture item 999")
    }

    func testLegacyCollectionSettingsDefaultSafely() throws {
        let payload = try JSONDecoder().decode(CollectionSettingsPayload.self, from: Data(#"{"statuses":[{"id":"stored","name":"Stored","color":"teal","symbol":"shippingbox"}]}"#.utf8))
        XCTAssertEqual(payload.defaultStatusID, "stored")
        XCTAssertFalse(payload.barcodeRequired)
    }
}
