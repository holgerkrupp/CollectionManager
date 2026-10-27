import Foundation
import SwiftData
import Synchronization

/// Process-local optimistic fence for independent SwiftData contexts. Model
/// values remain context-confined; only per-collection revision counters cross
/// executors. Large disk saves never hold the short revision-snapshot lock.
nonisolated final class StoreWriteCoordinator: Sendable {
    typealias Snapshot = [UUID: UInt64]

    private enum RegistryKey: Hashable, Sendable {
        case disk([String])
        case memory(ObjectIdentifier)
    }
    private struct Entry: Sendable {
        let coordinator: StoreWriteCoordinator
        // Retaining an in-memory container prevents ObjectIdentifier reuse from
        // accidentally assigning a later, unrelated fixture the old revisions.
        let memoryContainer: ModelContainer?
    }
    private static let registry = Mutex<[RegistryKey: Entry]>([:])
    private let revisions = Mutex<Snapshot>([:])
    private let commitGate = Mutex<Void>(())

    static func forContainer(_ container: ModelContainer) -> StoreWriteCoordinator {
        let diskURLs = container.configurations.filter { !$0.isStoredInMemoryOnly }.map {
            $0.url.standardizedFileURL.resolvingSymlinksInPath().path
        }.sorted()
        let key: RegistryKey = diskURLs.isEmpty ? .memory(ObjectIdentifier(container)) : .disk(diskURLs)
        return registry.withLock { entries in
            if let existing = entries[key] { return existing.coordinator }
            let coordinator = StoreWriteCoordinator()
            entries[key] = Entry(coordinator: coordinator, memoryContainer: diskURLs.isEmpty ? container : nil)
            return coordinator
        }
    }

    func snapshot() -> Snapshot { revisions.withLock { $0 } }

    /// Transport bookkeeping intentionally does not invalidate domain reads.
    /// Domain, membership and web-configuration changes do invalidate them.
    static func changedCollections(in context: ModelContext) -> Set<UUID> {
        var collections = Set<UUID>()
        for model in context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray {
            switch model {
            case let value as CollectionRecord: collections.insert(value.id)
            case let value as CollectionMemberRecord: collections.insert(value.collectionID)
            case let value as ItemRecord: collections.insert(value.collectionID)
            case let value as ItemRatingRecord: collections.insert(value.collectionID)
            case let value as ItemCommentRecord: collections.insert(value.collectionID)
            case let value as EventRecord: collections.insert(value.collectionID)
            case let value as WebSyncRecord: collections.insert(value.collectionID)
            default: break
            }
        }
        return collections
    }

    /// A competing save fails immediately rather than blocking the UI behind a
    /// large import. Revisions advance only after the actual store save succeeds.
    func commit(expected: Snapshot?, changedCollections: Set<UUID>, save: () throws -> Void) throws -> Snapshot {
        guard changedCollections.isEmpty || expected != nil else { throw RepositoryError.saveFailed }
        guard let committed = try commitGate.withLockIfAvailable({ _ -> Snapshot in
            if let expected {
                let matches = revisions.withLock { current in
                    changedCollections.allSatisfy { current[$0, default: 0] == expected[$0, default: 0] }
                }
                guard matches else { throw RepositoryError.saveFailed }
            }
            try save()
            return revisions.withLock { current in
                for collection in changedCollections { current[collection, default: 0] &+= 1 }
                return current
            }
        }) else { throw RepositoryError.saveFailed }
        return committed
    }
}
