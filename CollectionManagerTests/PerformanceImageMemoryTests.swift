import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import CollectionManager

/// Actual encoded JPEGs and SQLite reads, with bounded process/disk budgets.
/// Memory is sampled at named phases; none of these snapshots is a peak claim.
@MainActor final class PerformanceImageMemoryTests: XCTestCase {
    func testMeasuredImageHeavyHostPipeline() async throws {
        let jpeg = try encodedImage(salt: 0)
        for count in [1_000, 10_000, 50_000] {
            let report = try await measure(count: count, jpeg: jpeg)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("CM_IMAGE_MEMORY \(String(decoding: data, as: UTF8.self))")
        }
    }

    private func measure(count: Int, jpeg: Data) async throws -> [String: Any] {
        let imageBytes = jpeg.count * count
        // Cap logical compressed image content at 512 MiB, leaving headroom
        // for SQLite pages, model/value objects, the cache and framework state.
        try XCTSkipIf(imageBytes > 512 * 1_024 * 1_024, "Fixture exceeds bounded image-content budget")
        let before = try memorySnapshot()
        try XCTSkipIf(before.footprint + UInt64(imageBytes) > 1_600 * 1_024 * 1_024,
                      "Host process has insufficient headroom for this measurement")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CM-image-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("images.store")
        let collectionID = UUID()
        let seedStart = ProcessInfo.processInfo.systemUptime
        try autoreleasepool { try seed(count: count, jpeg: jpeg, collectionID: collectionID, at: url) }
        let seedMS = milliseconds(since: seedStart)
        let afterSeed = try memorySnapshot()
        let storeBytes = try directoryBytes(directory)
        XCTAssertLessThan(storeBytes, 2 * 1_024 * 1_024 * 1_024)

        let container = try PersistentStoreBootstrap.makeContainer(at: url)
        let fetchStart = ProcessInfo.processInfo.systemUptime
        var loaded = try await CollectionBackgroundRepository(container: container).items(in: collectionID)
        let fetchMS = milliseconds(since: fetchStart)
        XCTAssertEqual(loaded.count, count)
        let retainedOriginalBytes = loaded.reduce(0) { $0 + ($1.imageData?.count ?? 0) }
        XCTAssertEqual(retainedOriginalBytes, imageBytes)
        let afterFetch = try memorySnapshot()
        // This is a safety stop, not a release performance threshold.
        try XCTSkipIf(afterFetch.footprint > 2 * 1_024 * 1_024 * 1_024,
                      "Process footprint exceeded the measurement safety budget")

        let cache = ItemThumbnailCache()
        let firstDecodeStart = ProcessInfo.processInfo.systemUptime
        let firstData = try XCTUnwrap(loaded.first?.imageData)
        let first = await cache.thumbnail(for: firstData)
        let firstDecodeMS = milliseconds(since: firstDecodeStart)
        let thumbnail = try XCTUnwrap(first)
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 192)
        let scanStart = ProcessInfo.processInfo.systemUptime
        for (index, item) in loaded.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let bytes = item.imageData else { XCTFail("Missing image bytes"); continue }
            let decoded = await cache.thumbnail(for: bytes)
            XCTAssertNotNil(decoded)
        }
        let repeatedThumbnailScanMS = milliseconds(since: scanStart)
        // Exercise actual eviction with 160 distinct encoded scenes, rather
        // than inferring bounds from the favorable repeated-image cache hit.
        let distinctStart = ProcessInfo.processInfo.systemUptime
        for salt in 1...160 {
            let bytes = try autoreleasepool { try encodedImage(salt: salt) }
            let decoded = await cache.thumbnail(for: bytes)
            XCTAssertNotNil(decoded)
        }
        let distinctDecodeMS = milliseconds(since: distinctStart)
        let cachedBytes = await cache.cachedByteCount
        let cachedCount = await cache.cachedImageCount
        XCTAssertLessThanOrEqual(cachedBytes, 32 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(cachedCount, 128)
        XCTAssertGreaterThan(cachedCount, 100)
        let afterThumbnails = try memorySnapshot()
        await cache.removeAll()
        loaded.removeAll(keepingCapacity: false)
        let afterRelease = try memorySnapshot()
        return [
            "items": count, "jpeg_width": 512, "jpeg_height": 512, "jpeg_bytes_each": jpeg.count,
            "retained_original_logical_bytes": retainedOriginalBytes, "store_files_bytes": storeBytes,
            "seed_ms": seedMS, "repository_fetch_decode_ms": fetchMS,
            "first_thumbnail_decode_ms": firstDecodeMS,
            "repeated_image_thumbnail_requests_ms": repeatedThumbnailScanMS,
            "distinct_160_thumbnail_decode_ms": distinctDecodeMS,
            "cached_decoded_pixel_bytes": cachedBytes, "cached_image_count": cachedCount,
            "memory_before": before.dictionary, "memory_after_seed": afterSeed.dictionary,
            "memory_after_fetch": afterFetch.dictionary, "memory_after_thumbnails": afterThumbnails.dictionary,
            "memory_after_release": afterRelease.dictionary
        ]
    }

    private func seed(count: Int, jpeg: Data, collectionID: UUID, at url: URL) throws {
        let container = try PersistentStoreBootstrap.makeContainer(at: url)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // The seed source shares one Data buffer intentionally. The measured
        // fetch below reads image blobs from distinct SQLite item records.
        for var item in CollectionPerformanceFixture.items(count: count, collectionID: collectionID) {
            item.imageData = jpeg
            context.insert(ItemRecord(from: item))
        }
        try context.save()
    }

    private struct MemorySnapshot {
        let resident: UInt64
        let footprint: UInt64
        var dictionary: [String: UInt64] { ["resident_bytes": resident, "physical_footprint_bytes": footprint] }
    }

    private func memorySnapshot() throws -> MemorySnapshot {
        var basic = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: basic) / MemoryLayout<natural_t>.size)
        let basicCapacity = Int(basicCount)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: basicCapacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<natural_t>.size)
        let vmCapacity = Int(vmCount)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: vmCapacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        guard basicResult == KERN_SUCCESS, vmResult == KERN_SUCCESS else {
            throw NSError(domain: NSMachErrorDomain, code: Int(basicResult == KERN_SUCCESS ? vmResult : basicResult))
        }
        return MemorySnapshot(resident: basic.resident_size, footprint: vm.phys_footprint)
    }

    private func directoryBytes(_ directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    private func milliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    private func encodedImage(salt: Int) throws -> Data {
        let side = 512
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                             bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for stripe in 0..<128 {
            context.setFillColor(CGColor(red: CGFloat(stripe) / 128, green: 0.35,
                                         blue: 1 - CGFloat(stripe) / 128, alpha: 1))
            context.fill(CGRect(x: stripe * 4, y: 0, width: 4, height: side))
        }
        if salt > 0 {
            for bit in 0..<8 {
                let value: CGFloat = (salt & (1 << bit)) == 0 ? 0 : 1
                context.setFillColor(CGColor(gray: value, alpha: 1))
                context.fill(CGRect(x: bit * 32, y: 0, width: 32, height: 32))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
