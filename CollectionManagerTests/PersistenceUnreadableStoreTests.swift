import XCTest
@testable import CollectionManager

final class PersistenceUnreadableStoreTests: XCTestCase {
    @MainActor func testUnreadableExistingStoreFailsWithoutReplacingItsBytes() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CollectionManager", withExtension: "store"))
        let store = directory.appendingPathComponent("unreadable.store")
        try manager.copyItem(at: original, to: store)
        let bytes = try Data(contentsOf: store)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
            try? manager.removeItem(at: directory)
        }
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)
        guard !manager.isReadableFile(atPath: store.path) else { throw XCTSkip("Host bypasses POSIX read permissions") }
        XCTAssertThrowsError(try PersistentStoreBootstrap.makeContainer(at: store)) {
            XCTAssertEqual(PersistentStoreBootstrap.failure(for: $0).phase, .recoverableFailure)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
        XCTAssertEqual(try Data(contentsOf: store), bytes)
    }
}
