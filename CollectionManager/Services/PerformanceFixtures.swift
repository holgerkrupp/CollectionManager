import Foundation

/// Deterministic data sizes used for Instruments and XCTest performance runs.
/// The fixture intentionally omits full-resolution images by default; callers
/// can opt into bounded thumbnails when measuring image memory behavior.
enum CollectionPerformanceFixture {
    static let sizes = [1_000, 10_000, 25_000]

    static func items(count: Int, collectionID: UUID = UUID(), includeThumbnails: Bool = false) -> [CollectionItem] {
        let states = ItemState.allCases
        let thumbnail = includeThumbnails ? Data(repeating: 0, count: 32 * 32 * 4) : nil
        return (0..<count).map { index in
            CollectionItem(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1)) ?? UUID(),
                collectionID: collectionID,
                title: "Fixture item \(index)",
                brand: "Brand \(index % 100)",
                variant: "Variant \(index % 20)",
                itemDescription: "Deterministic performance fixture",
                state: states[index % states.count],
                quantity: (index % 4) + 1,
                barcode: nil,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                consumedAt: nil,
                tags: ["fixture", "group-\(index % 25)"],
                metadata: ["custom.fixtureIndex": .integer(index)],
                imageSystemName: "shippingbox.fill",
                imageData: thumbnail,
                importSourceKey: "fixture-\(index)"
            )
        }
    }
}
