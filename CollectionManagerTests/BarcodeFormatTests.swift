import XCTest
@testable import CollectionManager

final class BarcodeFormatTests: XCTestCase {
    func testSupportedEANAndUPCAFormatsAndInvalidCheckDigits() {
        XCTAssertEqual(Barcode(rawValue: "96385074", type: "EAN-8")?.value, "96385074")
        XCTAssertEqual(Barcode(rawValue: "4006381333931")?.value, "4006381333931")
        XCTAssertEqual(Barcode(rawValue: "036000291452")?.value, "0036000291452")
        for invalid in ["96385075", "4006381333932", "036000291453", "٠٠٠٠٠٠٠0"] {
            XCTAssertNil(Barcode(rawValue: invalid))
        }
    }

    func testUPCEUsesScannerSymbologyAndGS1ExpansionBeforeChecksum() throws {
        // GS1 General Specifications §5.2.2.4 zero-suppression examples:
        // https://ref.gs1.org/standards/genspecs/24.0.0/
        for (compressed, expanded) in [("01234558", "0012345000058"),
                                       ("04567840", "0045670000080"),
                                       ("03456703", "0034000005673"),
                                       ("09847531", "0098400000751")] {
            let barcode = try XCTUnwrap(Barcode(rawValue: compressed, type: "UPC-E"))
            XCTAssertEqual(barcode.value, expanded)
            XCTAssertEqual(Barcode(rawValue: barcode.value, type: barcode.type), barcode)
        }
        XCTAssertNil(Barcode(rawValue: "01234559", type: "UPC-E"))
    }
}
