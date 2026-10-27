import XCTest
@testable import CollectionManager

final class ImportParsingTests: XCTestCase {
    func testQuotedCSVPreservesEscapesNewlinesAndDuplicateHeaders() throws {
        let input = "Title,Title,Note\r\n\"A, B\",Second,\"He said \"\"yes\"\"\r\nnext line\"\r\n"
        let table = try CollectionImporter().parseTable(Data(input.utf8))
        XCTAssertEqual(table.headers, ["Title", "Title 2", "Note"])
        XCTAssertEqual(table.rows, [["A, B", "Second", "He said \"yes\"\r\nnext line"]])
    }
    func testSpreadsheetDelimitersAndMissingCells() {
        let importer = CollectionImporter()
        for delimiter in CSVDelimiter.allCases {
            let text = "Title\(delimiter.character)Brand\nBook\(delimiter.character)Publisher\nOther"
            let rows = importer.rows(in: text, delimiter: delimiter)
            let table = importer.makeTable(rows: rows, firstRowIsHeader: true)
            XCTAssertEqual(table.headers, ["Title", "Brand"])
            XCTAssertEqual(table.rows.last, ["Other", ""])
        }
    }
    func testInvalidUTF8DoesNotMasqueradeAsEmptyTable() {
        XCTAssertThrowsError(try CollectionImporter().parseTable(Data([0xff, 0xfe, 0xff])))
    }
    func testMetadataRoundTripPreservesTypedValues() throws {
        let values: [String: MetadataValue] = ["text": .string("Arabic العربية"), "integer": .integer(3), "number": .decimal(1.5), "flag": .boolean(true), "date": .date(Date(timeIntervalSince1970: 42))]
        XCTAssertEqual(try JSONDecoder().decode([String: MetadataValue].self, from: JSONEncoder().encode(values)), values)
    }
    func testImportedDateRejectsInvalidDayAndNormalizesPartialDates() {
        XCTAssertNil(MetadataDateParser.parse("2026-02-30"))
        XCTAssertNotNil(MetadataDateParser.parse("2026-02"))
        XCTAssertNotNil(MetadataDateParser.parse("2026-W01"))
    }
}
