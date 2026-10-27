import Foundation

nonisolated enum LibraryStoreEnvironment: String, Sendable { case development = "Development", production = "Production" }
nonisolated enum LibraryStoreChoice: Sendable { case none, confirmExistingEnvironment, createDevelopmentLibrary, mismatchedEnvironment }
nonisolated struct LibraryStoreEnvironmentReview: Error, Sendable {
    let choice: LibraryStoreChoice
    let existingStoreURL: URL
    let expected: LibraryStoreEnvironment
}

/// Separate local graphs as well as engine state. An old unmarked store is
/// preserved and needs an explicit decision; a known opposite environment can
/// never be overridden as an automatic recovery operation.
nonisolated enum StoreEnvironmentPolicy {
    static func storeURL(baseDirectory: URL, environment: LibraryStoreEnvironment) -> URL {
        let directory = environment == .development ? baseDirectory.appendingPathComponent("Development", isDirectory: true) : baseDirectory
        return directory.appendingPathComponent("CollectionManager.store")
    }
    static func markerURL(for store: URL) -> URL { URL(fileURLWithPath: store.path + ".environment") }

    static func validate(store: URL, legacyStore: URL, environment: LibraryStoreEnvironment,
                         userConfirmed: Bool = false, fileManager: FileManager = .default) throws {
        if environment == .development, !fileManager.fileExists(atPath: store.path),
           fileManager.fileExists(atPath: legacyStore.path), !userConfirmed {
            throw LibraryStoreEnvironmentReview(choice: .createDevelopmentLibrary, existingStoreURL: legacyStore, expected: environment)
        }
        guard fileManager.fileExists(atPath: store.path) else { return }
        let marker = markerURL(for: store)
        if fileManager.fileExists(atPath: marker.path) {
            let value = String(data: try Data(contentsOf: marker), encoding: .utf8) ?? ""
            if value == environment.rawValue { return }
            if LibraryStoreEnvironment(rawValue: value) != nil {
                throw LibraryStoreEnvironmentReview(choice: .mismatchedEnvironment, existingStoreURL: store, expected: environment)
            }
        }
        guard userConfirmed else {
            throw LibraryStoreEnvironmentReview(choice: .confirmExistingEnvironment, existingStoreURL: store, expected: environment)
        }
    }

    static func record(_ environment: LibraryStoreEnvironment, for store: URL) throws {
        try Data(environment.rawValue.utf8).write(to: markerURL(for: store), options: .atomic)
    }
}
