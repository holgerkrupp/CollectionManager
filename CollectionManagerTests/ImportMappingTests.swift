import XCTest
@testable import CollectionManager

@MainActor final class ImportMappingTests: XCTestCase {
    func testSuggestionsRecognizeStandardExistingAndTypedUnknownColumns() {
        let rating = MetadataFieldDefinition(name: "Café Rating", type: .number)
        let table = CSVImportTable(
            headers: ["Product", "cafe_rating", "Price", "Purchased Date", "Enabled", "Colour", "Misc", "Blank"],
            rows: [["Book", "4", "2.5", "2026-10-01", "yes", "red", "42", ""],
                   ["Game", "5", "3.75", "2026-11-03", "no", "#112233", "free text", ""]])
        XCTAssertEqual(CollectionImporter().suggestMapping(for: table, existingMetadataFields: [rating]), [
            .standard(.title), .existingMetadata(rating.id), .newMetadata(.number),
            .newMetadata(.date), .newMetadata(.boolean), .newMetadata(.color),
            .newMetadata(.text), .newMetadata(.text)
        ])
    }

    func testOptionalTitleSuggestionUsesPopulatedTextRatherThanNumericIdentifier() {
        let importer = CollectionImporter()
        let table = CSVImportTable(headers: ["Serial", "Caption"], rows: [["24", "Blue box"], ["25", "Red box"]])
        let automatic = importer.suggestMapping(for: table, existingMetadataFields: [])
        XCTAssertFalse(automatic.contains(.standard(.title)))
        let reviewed = importer.suggestMapping(for: table, existingMetadataFields: [], ensuresTitleColumn: true)
        XCTAssertEqual(reviewed[1], .standard(.title))
        let preparation = importer.prepareImport(from: table, mapping: reviewed, existingMetadataFields: [])
        XCTAssertEqual(preparation.drafts.map(\.title), ["Blue box", "Red box"])
        XCTAssertEqual(preparation.newMetadataFields.map(\.name), ["Serial"])
    }

    func testExistingAndNewMetadataParseTypedValuesAndOmitInvalidCells() throws {
        let amount = MetadataFieldDefinition(name: "Amount", type: .number)
        let purchased = MetadataFieldDefinition(name: "Purchased Date", type: .date)
        let enabled = MetadataFieldDefinition(name: "Enabled", type: .boolean)
        let table = CSVImportTable(headers: ["Title", "Amount", "Purchased Date", "Enabled", "Colour", "Edition"], rows: [
            ["First", " 1,5 ", "2026-10-27", " yes ", " #112233 ", " First edition "],
            ["Second", "not a number", "2026-02-30", "perhaps", "", ""]
        ])
        let preparation = CollectionImporter().prepareImport(from: table,
            mapping: [.standard(.title), .existingMetadata(amount.id), .existingMetadata(purchased.id),
                      .existingMetadata(enabled.id), .newMetadata(.color), .newMetadata(.text)],
            existingMetadataFields: [amount, purchased, enabled])
        XCTAssertEqual(preparation.drafts.count, 2)
        let first = try XCTUnwrap(preparation.drafts.first)
        XCTAssertEqual(first.metadata[amount.storageKey], .decimal(1.5))
        XCTAssertEqual(first.metadata[enabled.storageKey], .boolean(true))
        guard case .date(let date)? = first.metadata[purchased.storageKey] else { return XCTFail("Expected a typed date") }
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(calendar.component(.year, from: date), 2026)
        XCTAssertEqual(calendar.component(.month, from: date), 10)
        XCTAssertEqual(calendar.component(.day, from: date), 27)
        let colour = try XCTUnwrap(preparation.newMetadataFields.first(where: { $0.name == "Colour" }))
        let edition = try XCTUnwrap(preparation.newMetadataFields.first(where: { $0.name == "Edition" }))
        XCTAssertEqual(first.metadata[colour.storageKey], .string("#112233"))
        XCTAssertEqual(first.metadata[edition.storageKey], .string("First edition"))
        XCTAssertTrue(preparation.drafts[1].metadata.isEmpty)
        XCTAssertEqual(preparation.metadataFields.map(\.id), [amount.id, purchased.id, enabled.id, colour.id, edition.id])
    }

    func testConditionalStatusAndMetadataPreserveExplicitVersusDefaultProvenance() throws {
        let score = MetadataFieldDefinition(name: "Score", type: .number)
        let table = CSVImportTable(headers: ["Title", "Status", "Shelf", "Supplier"], rows: [
            ["Conditional", "", " New ", " ACME "],
            ["Explicit", "consumed", "other", "ACME"],
            ["Collection default", "", "other", "other"]
        ])
        let rules = [
            ConditionalMappingRule(sourceColumn: "sHeLf", equalsValue: " new ", action: .status("stored")),
            ConditionalMappingRule(sourceColumn: "Supplier", equalsValue: "acme", action: .status("removed-status")),
            ConditionalMappingRule(sourceColumn: "supplier", equalsValue: "Acme", action: .metadata(fieldID: score.id, value: " 2,5 "))
        ]
        let preparation = CollectionImporter().prepareImport(from: table,
            mapping: [.standard(.title), .standard(.state), .ignore, .ignore],
            existingMetadataFields: [score], conditionalRules: rules,
            validStatusIDs: ["wanted", "stored", "consumed"])
        XCTAssertEqual(preparation.drafts.map(\.state), [.stored, .consumed, .wanted])
        XCTAssertEqual(preparation.drafts.map(\.stateWasExplicit), [true, true, false])
        XCTAssertEqual(preparation.drafts[0].metadata[score.storageKey], .decimal(2.5))
        XCTAssertEqual(preparation.drafts[1].metadata[score.storageKey], .decimal(2.5))
        XCTAssertNil(preparation.drafts[2].metadata[score.storageKey])
        // Wanted is the parser's placeholder, not an explicit user choice.
        // Persistence applies the configured collection default to the last row.
        XCTAssertFalse(try XCTUnwrap(preparation.drafts.last).stateWasExplicit)
    }

    func testDuplicateNewFieldNamesStayDistinctAndTheirIDsAreSharedAcrossRows() throws {
        let existing = MetadataFieldDefinition(name: "Price", type: .number)
        let table = CSVImportTable(headers: ["Title", "price", "Price", "PRICE"],
                                   rows: [["One", "2", "3", "4"], ["Two", "5", "6", "7"]])
        let preparation = CollectionImporter().prepareImport(from: table,
            mapping: [.standard(.title), .newMetadata(.number), .newMetadata(.number), .newMetadata(.number)],
            existingMetadataFields: [existing])
        XCTAssertEqual(preparation.newMetadataFields.map(\.name), ["Price 2", "Price 3", "Price 4"])
        XCTAssertEqual(Set(preparation.newMetadataFields.map(\.id)).count, 3)
        XCTAssertFalse(preparation.newMetadataFields.contains { $0.id == existing.id })
        for (index, field) in preparation.newMetadataFields.enumerated() {
            XCTAssertEqual(preparation.drafts[0].metadata[field.storageKey], .decimal(Double(index + 2)))
            XCTAssertEqual(preparation.drafts[1].metadata[field.storageKey], .decimal(Double(index + 5)))
        }
        XCTAssertNil(preparation.drafts[0].metadata[existing.storageKey])
    }

    func testComposedTitlesDescriptionsTagDedupAndSourceIDsRemainAvailableForReview() throws {
        let table = CSVImportTable(headers: ["Model", "Colour", "First note", "Second note", "Tags", "More tags", "External ID", "Quantity"], rows: [
            ["Console", "Blue", "First", "Second", "Alpha; alpha | Beta/BETA, Gamma", "beta; Delta", "source-42", "0"],
            ["Console", "Red", "", "Only note", "Alpha", "alpha|Beta", "source-42", "2"]
        ])
        let preparation = CollectionImporter().prepareImport(from: table,
            mapping: [.standard(.title), .newMetadata(.color), .standard(.description), .standard(.description),
                      .standard(.tags), .standard(.tags), .ignore, .standard(.quantity)],
            existingMetadataFields: [], sourceIdentifierColumn: 6, titleColumns: [1, 0])
        XCTAssertEqual(preparation.drafts.map(\.title), ["Blue Console", "Red Console"])
        XCTAssertEqual(preparation.drafts.map(\.description), ["First · Second", "Only note"])
        XCTAssertEqual(preparation.drafts[0].tags, ["Alpha", "Beta", "Gamma", "Delta"])
        XCTAssertEqual(preparation.drafts[1].tags, ["Alpha", "Beta"])
        XCTAssertEqual(preparation.drafts.map(\.quantity), [1, 2])
        XCTAssertEqual(preparation.drafts.map(\.sourceIdentifier), ["source-42", "source-42"])
        // Mapping preserves review rows and source provenance; repository import
        // policy decides source-key deduplication after the user reviews them.
        XCTAssertEqual(preparation.drafts.count, 2)
        let colour = try XCTUnwrap(preparation.newMetadataFields.first)
        XCTAssertEqual(preparation.drafts[0].metadata[colour.storageKey], .string("Blue"))
    }

    func testProductMetadataMappingReusesKnownFieldsAndCreatesOnlyExplicitNewFields() throws {
        let score = MetadataFieldDefinition(name: "Café Score", type: .number)
        let importer = CollectionImporter()
        let headers = ["cafe_score", "Unknown provider value", "Colour"]
        let suggested = importer.suggestMetadataMapping(headers: headers, existingMetadataFields: [score])
        XCTAssertEqual(suggested, [.existingMetadata(score.id), .ignore, .ignore])
        let preparation = importer.prepareMetadataMapping(headers: headers, values: ["4,5", "private raw text", "#AABBCC"],
            mapping: [.existingMetadata(score.id), .ignore, .newMetadata(.color)], existingMetadataFields: [score])
        XCTAssertEqual(preparation.metadata[score.storageKey], .decimal(4.5))
        XCTAssertEqual(preparation.newMetadataFields.map(\.name), ["Colour"])
        let colour = try XCTUnwrap(preparation.newMetadataFields.first)
        XCTAssertEqual(preparation.metadata[colour.storageKey], .string("#AABBCC"))
        XCTAssertEqual(preparation.metadata.count, 2)
    }

    func testMalformedQuotesFailBeforeReviewWhileEscapedMultilineCellsRemainValid() throws {
        let importer = CollectionImporter()
        for text in ["Title,Note\n\"Unclosed,rest\nSecond,row", "Title,Note\nValid,\"She said \"\"hello\"\""] {
            func check(_ error: Error) {
                guard let csvError = error as? CSVImportError,
                      case .unterminatedQuotedField = csvError else {
                    return XCTFail("Expected a typed unterminated-field error")
                }
            }
            XCTAssertThrowsError(try importer.parseTable(Data(text.utf8))) { check($0) }
            XCTAssertThrowsError(try importer.parseFile(Data(text.utf8), fileName: "malformed.csv")) { check($0) }
        }
        let valid = "Title,Note\n\"A \"\"quoted\"\" title\",\"Line one\nLine two\"\n"
        let parsed = try importer.parseFile(Data(valid.utf8), fileName: "valid.csv")
        XCTAssertEqual(parsed.text, valid)
        let table = try importer.parseTable(Data(valid.utf8))
        XCTAssertEqual(table.rows, [["A \"quoted\" title", "Line one\nLine two"]])
    }

}
