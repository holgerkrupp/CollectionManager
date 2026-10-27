import Foundation
import OSLog
import SwiftData
import SwiftUI

enum StoreStartupPhase: String, Sendable {
    case loading
    case ready
    case recoverableFailure
    case unrecoverableFailure
}

struct StoreStartupFailure: LocalizedError, Sendable {
    let phase: StoreStartupPhase
    let storeURL: URL
    let errorType: String

    var errorDescription: String? {
        "Collection Manager could not open its persistent library. Your existing store files were not deleted or replaced."
    }

    var recoveryMessage: String {
        switch phase {
        case .recoverableFailure:
            "Retry after checking available disk space, file permissions, or an iCloud/account transition."
        case .unrecoverableFailure:
            "The store may be incompatible or damaged. Export a diagnostic copy and contact support before taking any recovery action."
        case .loading, .ready:
            ""
        }
    }
}

enum PersistentStoreBootstrap {
    static let logger = Logger(subsystem: "de.holgerkrupp.CollectionManager", category: "store-startup")

    #if DEBUG
    private static let testStoreDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CollectionManager-tests-\(UUID().uuidString)", isDirectory: true)
    #endif

    static var storeURL: URL {
        #if DEBUG
        let process = ProcessInfo.processInfo
        if NSClassFromString("XCTestCase") != nil || process.environment["XCTestConfigurationFilePath"] != nil || process.environment["XCTestBundlePath"] != nil || process.arguments.contains("--ui-testing") {
            if let path = process.environment["CM_TEST_STORE_PATH"], path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                return URL(fileURLWithPath: path)
            }
            return testStoreDirectory.appendingPathComponent("CollectionManager.store")
        }
        #endif
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("CollectionManager", isDirectory: true).appendingPathComponent("CollectionManager.store")
    }

    static func makeContainer(at storeURL: URL = storeURL) throws -> ModelContainer {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        do {
            let schema = Schema(CollectionManagerSchemaV1.models)
            return try ModelContainer(for: schema, migrationPlan: CollectionManagerMigrationPlan.self, configurations: configuration)
        } catch {
            logger.error("Persistent store initialization failed: \(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
    }

    static func failure(for error: Error) -> StoreStartupFailure {
        let nsError = error as NSError
        let recoverable = nsError.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileNoSuchFileError, NSFileLockingError].contains(nsError.code)
        return StoreStartupFailure(phase: recoverable ? .recoverableFailure : .unrecoverableFailure, storeURL: storeURL, errorType: String(describing: type(of: error)))
    }

    /// Recovery only: called before a container is open, so this process has no
    /// writer. Preserve the raw database and its actual SQLite sidecars together.
    /// Reject a concurrent external writer rather than return a partial copy.
    static func makeSafeExport(from sourceURL: URL = storeURL, into destination: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let manager = FileManager.default
        let exportDirectory = destination.appendingPathComponent("CollectionManager-store-\(UUID().uuidString)", isDirectory: true)
        let candidates = [sourceURL, URL(fileURLWithPath: sourceURL.path + "-wal"), URL(fileURLWithPath: sourceURL.path + "-shm")]
        guard manager.fileExists(atPath: sourceURL.path) else { throw CocoaError(.fileNoSuchFile) }
        let before = try storeMemberSignatures(candidates)
        try manager.createDirectory(at: exportDirectory, withIntermediateDirectories: false)
        do {
            for source in candidates where before[source.path] != nil {
                try manager.copyItem(at: source, to: exportDirectory.appendingPathComponent(source.lastPathComponent))
            }
            guard try storeMemberSignatures(candidates) == before else { throw CocoaError(.fileReadUnknown) }
            return exportDirectory
        } catch {
            // Only our new incomplete export is removed; never touch originals.
            try? manager.removeItem(at: exportDirectory)
            throw error
        }
    }

    private static func storeMemberSignatures(_ members: [URL]) throws -> [String: String] {
        var result: [String: String] = [:]
        for member in members where FileManager.default.fileExists(atPath: member.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: member.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            result[member.path] = "\(size):\(modified)"
        }
        return result
    }

}

struct StoreRecoveryView: View {
    let failure: StoreStartupFailure
    let retry: () -> Void
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Your library needs attention")
                .font(.title2.weight(.semibold))
            Text(failure.localizedDescription)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(failure.recoveryMessage)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                Button("Export store copy") {
                    do { exportURL = try PersistentStoreBootstrap.makeSafeExport() }
                    catch { exportError = "The store copy could not be prepared." }
                }
                .buttonStyle(.bordered)
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share exported store copy", systemImage: "square.and.arrow.up")
                }
            }
            if let exportError {
                Text(exportError).font(.footnote).foregroundStyle(.red)
            }
            Text("Diagnostic type: \(failure.errorType)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: 620)
        .accessibilityElement(children: .contain)
    }
}
