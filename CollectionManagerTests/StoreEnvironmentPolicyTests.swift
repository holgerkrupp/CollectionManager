import XCTest
@testable import CollectionManager

@MainActor final class StoreEnvironmentPolicyTests: XCTestCase {
    private func withDirectory(_ test: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CollectionManager-environment-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory)
    }

    private func review(_ operation: () throws -> Void, expectedChoice: LibraryStoreChoice, existing: URL, environment: LibraryStoreEnvironment, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let review = error as? LibraryStoreEnvironmentReview else { return XCTFail("Expected an explicit library environment review", file: file, line: line) }
            XCTAssertEqual(review.choice, expectedChoice, file: file, line: line)
            XCTAssertEqual(review.existingStoreURL, existing, file: file, line: line)
            XCTAssertEqual(review.expected, environment, file: file, line: line)
        }
    }

    func testDevelopmentPathIsSeparatedFromProductionAndLegacyPath() throws {
        try withDirectory { directory in
            let development = StoreEnvironmentPolicy.storeURL(baseDirectory: directory, environment: .development)
            let production = StoreEnvironmentPolicy.storeURL(baseDirectory: directory, environment: .production)
            XCTAssertEqual(development, directory.appendingPathComponent("Development", isDirectory: true).appendingPathComponent("CollectionManager.store"))
            XCTAssertEqual(production, directory.appendingPathComponent("CollectionManager.store"))
            XCTAssertNotEqual(development, production)
            XCTAssertFalse(FileManager.default.fileExists(atPath: development.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: production.path))
        }
    }

    func testExistingUnmarkedLegacyRequiresExplicitDevelopmentChoiceWithoutTouchingOriginal() throws {
        try withDirectory { directory in
            let legacy = StoreEnvironmentPolicy.storeURL(baseDirectory: directory, environment: .production)
            let development = StoreEnvironmentPolicy.storeURL(baseDirectory: directory, environment: .development)
            let original = Data("Existing production-or-unknown user library".utf8)
            try original.write(to: legacy)
            review({ try StoreEnvironmentPolicy.validate(store: development, legacyStore: legacy, environment: .development) }, expectedChoice: .createDevelopmentLibrary, existing: legacy, environment: .development)
            XCTAssertEqual(try Data(contentsOf: legacy), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: development.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: StoreEnvironmentPolicy.markerURL(for: legacy).path))
            try StoreEnvironmentPolicy.validate(store: development, legacyStore: legacy, environment: .development, userConfirmed: true)
            // Confirmation authorizes a later new library; validation itself must
            // neither clone nor move nor silently relabel the old library.
            XCTAssertEqual(try Data(contentsOf: legacy), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: development.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: StoreEnvironmentPolicy.markerURL(for: legacy).path))
        }
    }

    func testUnmarkedProductionRequiresConfirmationAndDoesNotRelabelDuringValidation() throws {
        try withDirectory { directory in
            let store = StoreEnvironmentPolicy.storeURL(baseDirectory: directory, environment: .production)
            let original = Data([0, 1, 2, 3])
            try original.write(to: store)
            review({ try StoreEnvironmentPolicy.validate(store: store, legacyStore: store, environment: .production) }, expectedChoice: .confirmExistingEnvironment, existing: store, environment: .production)
            try StoreEnvironmentPolicy.validate(store: store, legacyStore: store, environment: .production, userConfirmed: true)
            XCTAssertEqual(try Data(contentsOf: store), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: StoreEnvironmentPolicy.markerURL(for: store).path))
        }
    }

    func testKnownOppositeEnvironmentCannotBeOverriddenByConfirmation() throws {
        try withDirectory { directory in
            let store = directory.appendingPathComponent("Fixture.store")
            let original = Data("Preserved library".utf8)
            try original.write(to: store)
            for (marked, expected) in [(LibraryStoreEnvironment.development, LibraryStoreEnvironment.production), (.production, .development)] {
                try StoreEnvironmentPolicy.record(marked, for: store)
                let marker = try Data(contentsOf: StoreEnvironmentPolicy.markerURL(for: store))
                for confirmed in [false, true] {
                    review({ try StoreEnvironmentPolicy.validate(store: store, legacyStore: store, environment: expected, userConfirmed: confirmed) }, expectedChoice: .mismatchedEnvironment, existing: store, environment: expected)
                    XCTAssertEqual(try Data(contentsOf: store), original)
                    XCTAssertEqual(try Data(contentsOf: StoreEnvironmentPolicy.markerURL(for: store)), marker)
                }
            }
        }
    }

    func testCorruptTextMarkerRequiresExplicitReviewAndPreservesEvidence() throws {
        try withDirectory { directory in
            let store = directory.appendingPathComponent("Fixture.store")
            try Data("Library bytes".utf8).write(to: store)
            let marker = StoreEnvironmentPolicy.markerURL(for: store)
            let corrupt = Data("unknown-environment-format".utf8)
            try corrupt.write(to: marker)
            review({ try StoreEnvironmentPolicy.validate(store: store, legacyStore: store, environment: .production) }, expectedChoice: .confirmExistingEnvironment, existing: store, environment: .production)
            try StoreEnvironmentPolicy.validate(store: store, legacyStore: store, environment: .production, userConfirmed: true)
            XCTAssertEqual(try Data(contentsOf: marker), corrupt)
        }
    }

    func testInvalidUTF8MarkerAlsoRequiresReviewRatherThanBypassingEnvironmentGate() throws {
        try withDirectory { directory in
            let store = directory.appendingPathComponent("Fixture.store")
            try Data("Library bytes".utf8).write(to: store)
            let marker = StoreEnvironmentPolicy.markerURL(for: store), corrupt = Data([0xFF, 0xFE, 0x80])
            try corrupt.write(to: marker)
            review({ try StoreEnvironmentPolicy.validate(store: store, legacyStore: store, environment: .production) }, expectedChoice: .confirmExistingEnvironment, existing: store, environment: .production)
            try StoreEnvironmentPolicy.validate(store: store, legacyStore: store, environment: .production, userConfirmed: true)
            XCTAssertEqual(try Data(contentsOf: marker), corrupt)
        }
    }

    func testMatchingMarkerAllowsReopenAndRecoveryCopyIncludesMarkerAndSQLiteSidecars() throws {
        try withDirectory { directory in
            let store = directory.appendingPathComponent("Fixture.store")
            let members = [store, URL(fileURLWithPath: store.path + "-wal"), URL(fileURLWithPath: store.path + "-shm")]
            for (index, member) in members.enumerated() { try Data([UInt8(index), 9, 8]).write(to: member) }
            try StoreEnvironmentPolicy.record(.production, for: store)
            try StoreEnvironmentPolicy.validate(store: store, legacyStore: store, environment: .production)
            let export = try PersistentStoreBootstrap.makeSafeExport(from: store, into: directory)
            let allMembers = members + [StoreEnvironmentPolicy.markerURL(for: store)]
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: export.path)), Set(allMembers.map(\.lastPathComponent)))
            for member in allMembers {
                XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent(member.lastPathComponent)), try Data(contentsOf: member))
            }
            let copiedStore = export.appendingPathComponent(store.lastPathComponent)
            try StoreEnvironmentPolicy.validate(store: copiedStore, legacyStore: copiedStore, environment: .production)
            review({ try StoreEnvironmentPolicy.validate(store: copiedStore, legacyStore: copiedStore, environment: .development, userConfirmed: true) }, expectedChoice: .mismatchedEnvironment, existing: copiedStore, environment: .development)
        }
    }
}
