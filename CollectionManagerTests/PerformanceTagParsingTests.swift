import XCTest
@testable import CollectionManager

final class PerformanceTagParsingTests: XCTestCase {
    func testEverySupportedDateSpellingAndAmbiguousPrecedenceSurviveFastPath() {
        let aprilThird = Date(timeIntervalSince1970: 1_743_638_400)
        for text in ["2025-04-03", "2025/04/03", "2025.04.03", "03-04-2025", "03/04/2025", "03.04.2025", "20250403"] {
            XCTAssertEqual(TagUtilities.dateValue(for: text), aprilThird, text)
        }
        let aprilThirteenth = Date(timeIntervalSince1970: 1_744_502_400)
        for text in ["04-13-2025", "04/13/2025", "04.13.2025"] {
            XCTAssertEqual(TagUtilities.dateValue(for: text), aprilThirteenth, text)
        }
        // yyyy can round-trip more than four digits; a fixed-length shape
        // optimization would silently reject previously accepted values.
        XCTAssertEqual(TagUtilities.dateValue(for: "10000-01-01"), Date(timeIntervalSince1970: 253_402_300_800))
        XCTAssertEqual(TagUtilities.dateValue(for: "  2025-04-03\n"), aprilThird)
    }

    func testNonDatesAndMalformedDatesRemainNonDates() {
        for text in ["fixture", "group-17", "Expiry 2025-04-03", "2025-4-3", "2025-02-30", "2025-01-01T00:00:00Z", "٢٠٢٥-٠٤-٠٣", "", "--/.."] {
            XCTAssertNil(TagUtilities.dateValue(for: text), text)
        }
        XCTAssertEqual(TagUtilities.dateTags(from: ["fixture", "2025-04-03", "group-17"]).keys.sorted(), ["2025-04-03"])
    }
}
