import XCTest
@testable import CollectionManager

@MainActor final class CSVImportAnalysisTests: XCTestCase {
    func testSourcePreservesImporterParsingMappingAndTitleSuggestion() throws {
        let metadata = MetadataFieldDefinition(name: "Score", type: .number)
        let text = "Label;Colour;Score\r\n\"A; B\";red;1.5\r\nSecond;blue;2.5"
        let actual = try CSVImportAnalysis.source(text: text, delimiter: .semicolon, firstRowIsHeader: true, metadataFields: [metadata])
        let importer = CollectionImporter()
        let expected = importer.makeTable(rows: importer.rows(in: text, delimiter: .semicolon), firstRowIsHeader: true)
        XCTAssertEqual(actual.table.headers, expected.headers)
        XCTAssertEqual(actual.table.rows, expected.rows)
        XCTAssertEqual(actual.table.rows.first?.first, "A; B")
        XCTAssertEqual(actual.suggestedMapping, importer.suggestMapping(for: expected, existingMetadataFields: [metadata], ensuresTitleColumn: true))
        XCTAssertEqual(actual.suggestedMapping[0], .standard(.title))
        XCTAssertEqual(actual.suggestedMapping[2], .existingMetadata(metadata.id))
    }

    func testColumnExamplesAreBoundedTrimmedAndKeepSourceOrder() throws {
        let table = CSVImportTable(headers: ["Details", "Empty"], rows: [["  first  ", " "], ["", ""], ["second"], ["first", ""], ["fourth", ""]])
        let analysis = try CSVImportAnalysis.mapping(table: table, mapping: [.newMetadata(.text), .ignore], titleColumns: [], existingItems: [], collectionID: UUID())
        XCTAssertEqual(analysis.columns[0]?.examples, ["first", "second", "first"])
        XCTAssertEqual(analysis.columns[0]?.populatedCount, 4)
        XCTAssertEqual(analysis.columns[1]?.examples, [])
        XCTAssertEqual(analysis.columns[1]?.populatedCount, 0)
        XCTAssertEqual(analysis.importableRowCount, 0)
        XCTAssertNil(analysis.exampleTitle)
    }

    func testInferenceUsesTheImportersSingleColumnRules() throws {
        let table = CSVImportTable(headers: ["Title", "Numeric details", "Harvest year", "Enabled", "Colour"], rows: [["One", "12.5", "2024", "yes", "red"], ["Two", "13.75", "2023", "off", "blue"]])
        let analysis = try CSVImportAnalysis.mapping(table: table, mapping: [.standard(.title), .newMetadata(.number), .newMetadata(.date), .newMetadata(.boolean), .newMetadata(.color)], titleColumns: [0], existingItems: [], collectionID: UUID())
        XCTAssertNil(analysis.columns[0]?.suggestedType)
        XCTAssertEqual(analysis.columns[1]?.suggestedType, .number)
        XCTAssertEqual(analysis.columns[2]?.suggestedType, .date)
        XCTAssertEqual(analysis.columns[3]?.suggestedType, .boolean)
        XCTAssertEqual(analysis.columns[4]?.suggestedType, .color)
        XCTAssertTrue(analysis.columns.values.allSatisfy { $0.unreadableCount == 0 })
    }

    func testWarningsOnlyAnalyzeChosenNewMetadataConversion() throws {
        let existing = UUID()
        let table = CSVImportTable(headers: ["Amount", "Date", "Enabled", "Ignored", "Existing"], rows: [
            ["1,5", "2024-01-01", " YES ", "nonsense", "nonsense"],
            ["invalid amount", "not a date", "perhaps", "another", "another"],
            [" ", "", " ", "", ""],
            ["2", "2023", "off", "last", "last"]
        ])
        let mapping: [ImportColumnDestination] = [.newMetadata(.number), .newMetadata(.date), .newMetadata(.boolean), .ignore, .existingMetadata(existing)]
        let analysis = try CSVImportAnalysis.mapping(table: table, mapping: mapping, titleColumns: [], existingItems: [], collectionID: UUID())
        XCTAssertEqual(analysis.columns[0]?.populatedCount, 3)
        XCTAssertEqual(analysis.columns[0]?.unreadableCount, 1)
        XCTAssertEqual(analysis.columns[0]?.firstUnreadable, "invalid amount")
        XCTAssertEqual(analysis.columns[1]?.unreadableCount, 1)
        XCTAssertEqual(analysis.columns[1]?.firstUnreadable, "not a date")
        XCTAssertEqual(analysis.columns[2]?.unreadableCount, 1)
        XCTAssertEqual(analysis.columns[2]?.firstUnreadable, "perhaps")
        XCTAssertEqual(analysis.columns[3]?.unreadableCount, 0)
        XCTAssertNil(analysis.columns[3]?.firstUnreadable)
        XCTAssertEqual(analysis.columns[4]?.unreadableCount, 0)
        let textOnly = try CSVImportAnalysis.mapping(table: table, mapping: Array(repeating: .newMetadata(.text), count: table.headers.count), titleColumns: [], existingItems: [], collectionID: UUID())
        XCTAssertTrue(textOnly.columns.values.allSatisfy { $0.unreadableCount == 0 && $0.firstUnreadable == nil })
    }

    func testComposedTitlesAndDuplicateCountsRespectCollectionScope() throws {
        let collectionID = UUID(), otherCollectionID = UUID()
        var existing = CollectionPerformanceFixture.items(count: 1, collectionID: collectionID)[0]
        existing.title = "Alpha Red"; existing.brand = "Brand"; existing.variant = "V"
        var unrelated = CollectionPerformanceFixture.items(count: 1, collectionID: otherCollectionID)[0]
        unrelated.title = "Beta Blue"; unrelated.brand = "Brand"; unrelated.variant = "V"
        let table = CSVImportTable(headers: ["Model", "Colour", "Brand", "Variant"], rows: [
            [" Alpha ", " Red ", " brand ", " v "],
            ["ALPHA", "RED", "BRAND", "V"],
            ["Beta", "Blue", "Brand", "V"],
            ["Beta", "Blue", "Brand", "V"],
            [" ", "", "ignored", "ignored"]
        ])
        let result = try CSVImportAnalysis.mapping(table: table, mapping: [.standard(.title), .newMetadata(.color), .standard(.brand), .standard(.variant)], titleColumns: [1, 0, 0, -1, 99], existingItems: [existing, unrelated], collectionID: collectionID)
        XCTAssertEqual(result.importableRowCount, 4)
        XCTAssertEqual(result.exampleTitle, "Alpha Red")
        // Two match the current collection and one repeats another source row;
        // the other collection's Beta does not count as an existing duplicate.
        XCTAssertEqual(result.duplicateTitleCount, 3)
    }

    func testAlreadyCancelledAnalysisRejectsSourceAndMapping() async throws {
        let source = Task.detached { () throws -> CSVSourceAnalysis in
            withUnsafeCurrentTask { $0?.cancel() }
            return try CSVImportAnalysis.source(text: "Title\nItem", delimiter: .comma, firstRowIsHeader: true, metadataFields: [])
        }
        do { _ = try await source.value; XCTFail("Cancelled source analysis must not publish a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        let mapping = Task.detached { () throws -> CSVMappingAnalysis in
            withUnsafeCurrentTask { $0?.cancel() }
            return try CSVImportAnalysis.mapping(table: CSVImportTable(headers: ["Title"], rows: [["Item"]]), mapping: [.standard(.title)], titleColumns: [0], existingItems: [], collectionID: UUID())
        }
        do { _ = try await mapping.value; XCTFail("Cancelled mapping analysis must not publish a result") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
