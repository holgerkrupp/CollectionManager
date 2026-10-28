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
    var requiredChoice: LibraryStoreChoice = .none
    var expectedEnvironment: LibraryStoreEnvironment? = nil

    var errorDescription: String? {
        if requiredChoice != .none {
            return String(localized: "Your existing library is preserved. Check its iCloud environment before opening this build.")
        }
        return String(localized: "Collection Manager could not open its persistent library. Your existing store files were not deleted or replaced.")
    }

    var recoveryMessage: String {
        switch requiredChoice {
        case .createDevelopmentLibrary:
            return String(localized: "This development build uses a separate local library and iCloud environment. Your original library stays untouched for the Production build.")
        case .confirmExistingEnvironment:
            return String(localized: "Confirm that this older library belongs to the environment shown below and the Apple Account currently signed into iCloud. Check the account in system settings and export a copy first if you are unsure.")
        case .mismatchedEnvironment:
            return String(localized: "This library is marked for another iCloud environment. Use the matching build; it will not be changed automatically.")
        case .none: break
        }
        return switch phase {
        case .recoverableFailure:
            String(localized: "Retry after checking available disk space, file permissions, or an iCloud/account transition.")
        case .unrecoverableFailure:
            String(localized: "The store may be incompatible or damaged. Export a diagnostic copy and contact support before taking any recovery action.")
        case .loading, .ready:
            ""
        }
    }
}

nonisolated enum PersistentStoreBootstrap {
    static let logger = Logger(subsystem: "de.holgerkrupp.CollectionManager", category: "store-startup")

    #if DEBUG
    private static let testStoreDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CollectionManager-tests-\(UUID().uuidString)", isDirectory: true)
    #endif

    static var libraryEnvironment: LibraryStoreEnvironment {
        #if DEBUG
        .development
        #else
        .production
        #endif
    }
    private static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CollectionManager", isDirectory: true)
    }
    private static var isTestProcess: Bool {
        #if DEBUG
        let process = ProcessInfo.processInfo
        return NSClassFromString("XCTestCase") != nil || process.environment["XCTestConfigurationFilePath"] != nil || process.environment["XCTestBundlePath"] != nil || process.arguments.contains("--ui-testing")
        #else
        false
        #endif
    }

    static var storeURL: URL {
        #if DEBUG
        let process = ProcessInfo.processInfo
        if NSClassFromString("XCTestCase") != nil || process.environment["XCTestConfigurationFilePath"] != nil || process.environment["XCTestBundlePath"] != nil || process.arguments.contains("--ui-testing") {
            if let name = process.environment["CM_TEST_STORE_NAME"], UUID(uuidString: name) != nil {
                return FileManager.default.temporaryDirectory.appendingPathComponent("CollectionManager-UI-" + name, isDirectory: true).appendingPathComponent("Library.store")
            }
            if let path = process.environment["CM_TEST_STORE_PATH"], path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                return URL(fileURLWithPath: path)
            }
            return testStoreDirectory.appendingPathComponent("CollectionManager.store")
        }
        #endif
        return StoreEnvironmentPolicy.storeURL(baseDirectory: baseDirectory, environment: libraryEnvironment)
    }

    static func makeContainer(at storeURL: URL = storeURL, allowEnvironmentSelection: Bool = false) throws -> ModelContainer {
        let managesEnvironment = !isTestProcess && storeURL.standardizedFileURL == self.storeURL.standardizedFileURL
        if managesEnvironment {
            try StoreEnvironmentPolicy.validate(store: storeURL,
                legacyStore: StoreEnvironmentPolicy.storeURL(baseDirectory: baseDirectory, environment: .production),
                environment: libraryEnvironment, userConfirmed: allowEnvironmentSelection)
        }
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: storeURL.path) {
            guard FileManager.default.isReadableFile(atPath: storeURL.path) else { throw CocoaError(.fileReadNoPermission) }
            guard FileManager.default.isWritableFile(atPath: storeURL.path) else { throw CocoaError(.fileWriteNoPermission) }
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else { throw CocoaError(.fileWriteNoPermission) }
        let configuration = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        do {
            let schema = Schema(CollectionManagerSchemaV2.models)
            let container = try ModelContainer(for: schema, migrationPlan: CollectionManagerMigrationPlan.self, configurations: configuration)
            if managesEnvironment { try StoreEnvironmentPolicy.record(libraryEnvironment, for: storeURL) }
            return container
        } catch {
            logger.error("Persistent store initialization failed: \(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
    }

    static func failure(for error: Error) -> StoreStartupFailure {
        if let review = error as? LibraryStoreEnvironmentReview {
            return StoreStartupFailure(phase: .recoverableFailure, storeURL: review.existingStoreURL,
                errorType: "Library environment review", requiredChoice: review.choice, expectedEnvironment: review.expected)
        }
        let nsError = error as NSError
        let recoverable = nsError.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileNoSuchFileError, NSFileLockingError, NSFileWriteOutOfSpaceError].contains(nsError.code)
        return StoreStartupFailure(phase: recoverable ? .recoverableFailure : .unrecoverableFailure, storeURL: storeURL, errorType: String(describing: type(of: error)))
    }

    /// Recovery only: called before a container is open, so this process has no
    /// writer. Preserve the raw database and its actual SQLite sidecars together.
    /// Reject a concurrent external writer rather than return a partial copy.
    static func makeSafeExport(from sourceURL: URL = storeURL, into destination: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let manager = FileManager.default
        let exportDirectory = destination.appendingPathComponent("CollectionManager-store-\(UUID().uuidString)", isDirectory: true)
        let candidates = [sourceURL, URL(fileURLWithPath: sourceURL.path + "-wal"), URL(fileURLWithPath: sourceURL.path + "-shm"), StoreEnvironmentPolicy.markerURL(for: sourceURL)]
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
    var selectEnvironment: (() -> Void)? = nil
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
            if let environment = failure.expectedEnvironment { LabeledContent("This build’s environment", value: environment.rawValue) }
            if let selectEnvironment {
                if failure.requiredChoice == .createDevelopmentLibrary {
                    Button("Create separate development library", action: selectEnvironment).buttonStyle(.borderedProminent)
                } else if failure.requiredChoice == .confirmExistingEnvironment {
                    Button("Confirm library environment and account", action: selectEnvironment).buttonStyle(.borderedProminent)
                }
            }
            HStack {
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                Button("Export store copy") {
                    do { exportURL = try PersistentStoreBootstrap.makeSafeExport(from: failure.storeURL) }
                    catch { exportError = String(localized: "The store copy could not be prepared.") }
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
