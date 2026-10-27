import XCTest
@testable import CollectionManager

@MainActor final class LocalizationFormattingTests: XCTestCase {
    func testIntegerMetadataUsesExplicitLocaleGrouping() {
        let value = MetadataValue.integer(12_345)
        XCTAssertEqual(value.displayValue(locale: Locale(identifier: "en_US")), "12,345")
        XCTAssertEqual(value.displayValue(locale: Locale(identifier: "de_DE")), "12.345")
    }

    func testDecimalMetadataUsesExplicitLocaleSeparators() {
        let value = MetadataValue.decimal(1_234.5)
        XCTAssertEqual(value.displayValue(locale: Locale(identifier: "en_US")), "1,234.5")
        XCTAssertEqual(value.displayValue(locale: Locale(identifier: "de_DE")), "1.234,5")
    }

    func testBooleanMetadataUsesSupportedEnglishAndSafeUnsupportedLocaleFallback() {
        for identifier in ["en_US", "de_DE"] {
            let locale = Locale(identifier: identifier)
            // 1.0 supports English. Formatting with another locale must keep a
            // usable English fallback without adding a partial app translation.
            XCTAssertEqual(MetadataValue.boolean(true).displayValue(locale: locale), "Yes")
            XCTAssertEqual(MetadataValue.boolean(false).displayValue(locale: locale), "No")
        }
    }

    func testDateMetadataUsesSuppliedLocaleWithoutChangingProcessLocale() {
        let value = MetadataValue.date(Date(timeIntervalSince1970: 1_704_110_400))
        let english = value.displayValue(locale: Locale(identifier: "en_US"))
        let german = value.displayValue(locale: Locale(identifier: "de_DE"))
        XCTAssertNotEqual(english, german)
        XCTAssertTrue(english.contains("2024"))
        XCTAssertTrue(german.contains("2024"))
    }

    func testFormattingCannotChangeEncodedValuesOrPersistedIdentifiers() throws {
        let value = MetadataValue.decimal(1_234.5)
        let before = try JSONEncoder().encode(value)
        _ = value.displayValue(locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(try JSONEncoder().encode(value), before)
        XCTAssertEqual(try JSONDecoder().decode(MetadataValue.self, from: before), value)
        _ = ItemState.stored.label
        _ = CollectionCategory.boardGames.name
        _ = TitleTagMode.firstSegment.label
        XCTAssertEqual(ItemState.stored.rawValue, "stored")
        XCTAssertEqual(CollectionCategory.boardGames.rawValue, "boardGames")
        XCTAssertEqual(TitleTagMode.firstSegment.rawValue, "firstSegment")
        XCTAssertEqual(CollectionCategory.games.detailFields.map(\.key), ["publisher", "platform", "genre", "releaseYear", "players"])
        XCTAssertEqual(CollectionCategory.games.pickerGroup, "Games & Play")
        XCTAssertEqual(CollectionCategory.products.pickerGroup, "Toys, Collectibles & General Products")
    }

    func testAuthoredNamesTextAndURLsRemainVerbatim() {
        let authored = "Mein eigener Status – 状態"
        let status = CollectionStatus(id: "authored-id", name: authored)
        let collection = CollectionModel(id: UUID(), name: "Collection", icon: "books.vertical", subtitle: "Custom subtitle", statuses: [status], defaultStatusID: status.id)
        XCTAssertEqual(collection.status(for: ItemState(rawValue: status.id)).name, authored)
        XCTAssertEqual(collection.caption, "Custom subtitle")
        XCTAssertEqual(MetadataValue.string(authored).displayValue(locale: Locale(identifier: "de_DE")), authored)
        let url = URL(string: "https://example.invalid/item?code=1234.50")!
        XCTAssertEqual(MetadataValue.url(url).displayValue(locale: Locale(identifier: "de_DE")), url.absoluteString)
    }

    func testSharingCaptionKeepsParticipantNamesAndUsesWholeTemplate() {
        var collection = CollectionModel(id: UUID(), name: "Collection", icon: "books.vertical", subtitle: "Private")
        collection.sharedWith = ["Zoë", "ليلى"]
        let participants = ListFormatter.localizedString(byJoining: collection.sharedWith)
        XCTAssertTrue(collection.caption.hasPrefix("Shared with "))
        XCTAssertTrue(collection.caption.contains(participants))
        XCTAssertTrue(collection.caption.contains("Zoë"))
        XCTAssertTrue(collection.caption.contains("ليلى"))
    }
}
