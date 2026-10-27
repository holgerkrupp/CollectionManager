import Foundation
import CryptoKit
import ImageIO

/// In-memory, bounded display derivatives. Original image bytes stay intact in
/// the host store/CloudKit. Actor isolation keeps decode/hash work off UI tasks.
actor ItemThumbnailCache {
    static let shared = ItemThumbnailCache()

    private struct Entry {
        let image: CGImage
        let byteCount: Int
        var lastUse: UInt64
    }

    private let maximumBytes: Int
    private let maximumCount: Int
    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0
    private(set) var cachedByteCount = 0
    var cachedImageCount: Int { entries.count }

    init(maximumBytes: Int = 32 * 1_024 * 1_024, maximumCount: Int = 128) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumCount = max(0, maximumCount)
    }

    func thumbnail(for data: Data, maxPixelDimension: Int = 192) -> CGImage? {
        guard !data.isEmpty else { return nil }
        let dimension = min(512, max(1, maxPixelDimension))
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "-\(dimension)"
        sequence &+= 1
        if var entry = entries[key] {
            entry.lastUse = sequence
            entries[key] = entry
            return entry.image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let bytes = image.bytesPerRow * image.height
        guard bytes <= maximumBytes, maximumCount > 0 else { return image }
        while entries.count >= maximumCount || cachedByteCount + bytes > maximumBytes {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            cachedByteCount -= oldest.value.byteCount
            entries.removeValue(forKey: oldest.key)
        }
        entries[key] = Entry(image: image, byteCount: bytes, lastUse: sequence)
        cachedByteCount += bytes
        return image
    }

    func removeAll() {
        entries.removeAll()
        cachedByteCount = 0
    }
}
