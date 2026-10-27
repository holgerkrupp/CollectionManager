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

    static var storeURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("CollectionManager", isDirectory: true).appendingPathComponent("CollectionManager.store")
    }

    static func makeContainer() throws -> ModelContainer {
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

    /// Copies all known SQLite store members to a temporary directory. The
    /// original files are never modified, deleted, or moved.
    static func makeSafeExport() throws -> URL {
        let exportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CollectionManager-store-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let candidates = [storeURL, storeURL.appendingPathExtension("shm"), storeURL.appendingPathExtension("wal")]
        for source in candidates where FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(at: source, to: exportDirectory.appendingPathComponent(source.lastPathComponent))
        }
        return exportDirectory
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
