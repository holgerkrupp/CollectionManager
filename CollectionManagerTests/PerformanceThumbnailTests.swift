import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CollectionManager

final class PerformanceThumbnailTests: XCTestCase {
    func testDownsamplingAndOrientationPreserveBoundedDisplaySize() async throws {
        let data = try encodedImage(width: 800, height: 400, orientation: 6)
        let cache = ItemThumbnailCache()
        let decoded = await cache.thumbnail(for: data, maxPixelDimension: 100)
        let image = try XCTUnwrap(decoded)
        XCTAssertEqual(image.width, 50)
        XCTAssertEqual(image.height, 100)
        let cached = await cache.thumbnail(for: data, maxPixelDimension: 100)
        let reused = try XCTUnwrap(cached)
        XCTAssertTrue(image === reused)
    }

    func testInvalidDataAndStrictCacheBudgets() async throws {
        let cache = ItemThumbnailCache(maximumBytes: 50_000, maximumCount: 1)
        let invalid = await cache.thumbnail(for: Data("not an image".utf8))
        XCTAssertNil(invalid)
        let empty = await cache.thumbnail(for: Data())
        XCTAssertNil(empty)
        let first = try encodedImage(width: 400, height: 200, orientation: 1)
        let second = try encodedImage(width: 400, height: 200, orientation: 6)
        _ = await cache.thumbnail(for: first, maxPixelDimension: 100)
        _ = await cache.thumbnail(for: second, maxPixelDimension: 100)
        let count = await cache.cachedImageCount
        let bytes = await cache.cachedByteCount
        XCTAssertEqual(count, 1)
        XCTAssertLessThanOrEqual(bytes, 50_000)
        // A derivative larger than the budget can display but is never retained.
        let tiny = ItemThumbnailCache(maximumBytes: 1)
        let image = await tiny.thumbnail(for: first, maxPixelDimension: 100)
        XCTAssertNotNil(image)
        let tinyCount = await tiny.cachedImageCount
        XCTAssertEqual(tinyCount, 0)
        await cache.removeAll()
        let cleared = await cache.cachedByteCount
        XCTAssertEqual(cleared, 0)
    }

    private func encodedImage(width: Int, height: Int, orientation: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.25, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
