import CloudKit
import CollaborationCloudKit
import CollaborationCore
import CollaborationDiagnostics
import CryptoKit
import Foundation
import SwiftData

/// The process owns one coordinator/pool. The retained legacy implementation
/// is never instantiated after this handoff path takes ownership.
@MainActor final class CloudKitSharingService {
    static let containerIdentifier = "iCloud.de.holgerkrupp.CollectionManager"
    static var isAvailable: Bool { LegacyCloudKitSharingService.isAvailable }
    static var environment: CollaborationEnvironment {
        #if DEBUG
        .development
        #else
        .production
        #endif
    }

    private let modelContainer: ModelContainer
    private let cloudContainer: CKContainer
    private var codec: CollectionRecordCodec?
    private var pool: CloudKitSyncEnginePool?
    private var accountPartition: String?
    private var activeSync: Task<Void, Error>?
    private var preparedPrivateZones: Set<CKRecordZone.ID> = []
    private(set) var needsContinuation = false
    private(set) var legacyReviewCount = 0
    private(set) var sharingSession: CollectionSharingSession?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        cloudContainer = CKContainer(identifier: Self.containerIdentifier)
    }

    func synchronize() async throws {
        if let activeSync { return try await activeSync.value }
        let task = Task { @MainActor in try await self.synchronizeWithRetry() }
        activeSync = task
        defer { activeSync = nil }
        try await task.value
    }

    private func synchronizeWithRetry() async throws {
        let retry = BoundedRetryPolicy(maximumAttempts: 4)
        for attempt in 1...retry.maximumAttempts {
            do { try await synchronizeWork(); return }
            catch {
                await pool?.shutdown()
                let failure = CollaborationErrorClassifier.classify(error)
                let retryAfter = (error as? CKError)?.retryAfterSeconds
                guard let delay = retry.delay(for: failure, after: attempt, retryAfter: retryAfter) else { throw error }
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func synchronizeWork() async throws {
        needsContinuation = false
        guard Self.isAvailable else { throw SharingError.unavailable }
        let account = try await currentAccountPartition()
        if let previous = accountPartition, previous != account {
            await pool?.shutdown()
            sharingSession = nil
            // Keep the original codec/pool identity so signing back in can
            // resume its registry entry and durable state without replacement.
            throw CollectionCodecError.accountPartitionMismatch
        }
        if codec == nil {
            let codec = CollectionRecordCodec(modelContainer: modelContainer, containerIdentifier: Self.containerIdentifier,
                                              environment: Self.environment, accountPartitionIdentifier: account)
            // Preserve opaque manual change tokens as recovery evidence only.
            // They are never interpreted as CKSyncEngine serialization.
            let legacy = UserDefaults.standard.dictionaryRepresentation().filter {
                $0.key.hasPrefix("cloudSync.")
            }
            let backup = try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
            try await codec.beginHandoff(legacyState: backup)
            try await discoverZones(codec)
            while try await codec.bootstrapPage(limit: 400) { try Task.checkCancellation() }
            let pool = try await CloudKitSyncEnginePool.shared(containerIdentifier: Self.containerIdentifier,
                environment: Self.environment, accountPartitionIdentifier: account, container: cloudContainer,
                stateStore: codec, delegate: codec, automaticallySync: false,
                subscriptionIDPrefix: "CollectionManager.package.v1")
            self.codec = codec
            accountPartition = account
            self.pool = pool
            sharingSession = makeSharingSession(codec: codec, pool: pool)
            try await refreshPlans()
            try await pool.start()
            await sharingSession?.storesDidLoad()
        }
        guard let codec, let pool else { throw SharingError.unavailable }
        if sharingSession == nil {
            sharingSession = makeSharingSession(codec: codec, pool: pool)
            try await refreshPlans()
            await sharingSession?.storesDidLoad()
        }
        try await pool.start()
        // Bounded passes avoid a busy retry loop when CloudKit rejects a row.
        // Unacknowledged journal generations stay durable for the next trigger.
        for _ in 0..<8 {
            _ = try await codec.stageRepositoryMutations(limit: 400)
            for scope in [CollaborationDatabaseScope.private, .shared] {
                let zones = try await codec.knownZones(in: scope)
                if scope == .private {
                    let authorized = Set(try await codec.authorizedNewPrivateZones())
                    for zone in zones where !preparedPrivateZones.contains(zone) {
                        guard authorized.contains(zone) else { throw CollectionCodecError.routingUnavailable }
                        _ = try await cloudContainer.privateCloudDatabase.save(CKRecordZone(zoneID: zone))
                        preparedPrivateZones.insert(zone)
                    }
                }
                try await pool.restorePendingChanges(in: scope)
                try await pool.fetchChanges(in: scope, zoneIDs: zones.isEmpty ? nil : zones)
                try await pool.sendChanges(in: scope, zoneIDs: zones.isEmpty ? nil : zones)
            }
            let pendingPrivate = try await codec.pendingLocalChanges(in: .private)
            let pendingShared = try await codec.pendingLocalChanges(in: .shared)
            let unstaged = try await codec.hasEligibleUnstagedMutations()
            if pendingPrivate.isEmpty && pendingShared.isEmpty && !unstaged { break }
        }
        try await refreshPlans()
        if let session = sharingSession {
            for plan in try await codec.sharePlans() {
                if let id = UUID(uuidString: plan.rootID) { _ = try await session.refresh(collectionID: id) }
            }
        }
        needsContinuation = try await codec.hasEligibleUnstagedMutations()
        legacyReviewCount = try await codec.unreconciledBaselineCount()
        if !needsContinuation { try await codec.completeHandoff() }
    }

    private func currentAccountPartition() async throws -> String {
        switch try await cloudContainer.accountStatus() {
        case .available: break
        case .noAccount: throw SharingError.noAccount
        case .restricted: throw SharingError.restricted
        default: throw SharingError.temporarilyUnavailable
        }
        let user = try await cloudContainer.userRecordID()
        return SHA256.hash(data: Data(user.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func discoverZones(_ codec: CollectionRecordCodec) async throws {
        for (scope, database) in [(CollaborationDatabaseScope.private, cloudContainer.privateCloudDatabase), (.shared, cloudContainer.sharedCloudDatabase)] {
            for zone in try await database.allRecordZones() where zone.zoneID.zoneName.hasPrefix("collection-") {
                guard let id = UUID(uuidString: String(zone.zoneID.zoneName.dropFirst("collection-".count))) else { continue }
                if scope == .private { preparedPrivateZones.insert(zone.zoneID) }
                // Fetch current share authority before staging collaborator writes.
                let rootID = CKRecord.ID(recordName: id.uuidString, zoneID: zone.zoneID)
                let root: CKRecord?
                do { root = try await database.record(for: rootID) }
                catch let error as CKError where error.code == .unknownItem { root = nil }
                var role: CollectionMemberRole = scope == .private ? .owner : .viewer
                var shareName: String?
                if let shareID = root?.share?.recordID {
                    guard let share = try await database.record(for: shareID) as? CKShare else { throw SharingError.invitationNotReady }
                    let access = CollectionSharingSession.authoritativeAccess(for: share)
                    role = access.canManageShare ? .owner : (access.canEdit ? .editor : .viewer)
                    shareName = shareID.recordName
                }
                try await codec.registerCollection(collectionID: id, zoneID: zone.zoneID, scope: scope,
                                                   shareRecordName: shareName, role: role)
                if let root { try await codec.applyRemoteChanges(records: [root], deletedRecordIDs: [], in: scope) }
            }
        }
    }

    private func refreshPlans() async throws {
        guard let codec, let sharingSession else { return }
        for plan in try await codec.sharePlans() {
            if let id = UUID(uuidString: plan.rootID) { sharingSession.setPlan(plan, for: id) }
        }
    }

    private func makeSharingSession(codec: CollectionRecordCodec, pool: CloudKitSyncEnginePool) -> CollectionSharingSession {
        CollectionSharingSession(configuration: CollaborationConfiguration(containerIdentifier: Self.containerIdentifier, environment: Self.environment), pool: pool,
            onAccess: { id, access, share in
                let role: CollectionMemberRole = access.canManageShare ? .owner : (access.canEdit ? .editor : .viewer)
                if let share {
                    try await codec.registerCollection(collectionID: id, zoneID: share.recordID.zoneID,
                        scope: role == .owner ? .private : .shared, shareRecordName: share.recordID.recordName, role: role)
                } else { try await codec.deactivateSharedCollection(collectionID: id) }
            }, onAccepted: { [weak self] share in
                let name = share.recordID.zoneID.zoneName
                guard name.hasPrefix("collection-"), let id = UUID(uuidString: String(name.dropFirst("collection-".count))) else { throw SharingError.invalidInvitation }
                let access = CollectionSharingSession.authoritativeAccess(for: share)
                try await codec.registerCollection(collectionID: id, zoneID: share.recordID.zoneID, scope: .shared,
                    shareRecordName: share.recordID.recordName, role: access.canEdit ? .editor : .viewer)
                guard let self else { throw SharingError.unavailable }
                // Import the precise root before CKSyncEngine can deliver a
                // child-first page; no whole-zone query is necessary.
                let rootID = CKRecord.ID(recordName: id.uuidString, zoneID: share.recordID.zoneID)
                let root = try await self.cloudContainer.sharedCloudDatabase.record(for: rootID)
                try await codec.applyRemoteChanges(records: [root], deletedRecordIDs: [], in: .shared)
                try await self.refreshPlans()
            }, onPreparing: { [weak self] _ in try await self?.synchronize() })
    }

    func legacyCandidates(limit: Int = 50, offset: Int = 0) async throws -> [CollectionLegacyCandidate] {
        guard let codec else { throw SharingError.unavailable }
        return try await codec.legacyCandidates(limit: limit, offset: offset)
    }

    func authorizeLegacyUpload(_ id: UUID) async throws {
        guard let codec else { throw SharingError.unavailable }
        try await codec.authorizeBaselineUpload(snapshotID: id)
    }

    func accept(_ metadata: CKShare.Metadata) async throws {
        if sharingSession == nil { try await synchronize() }
        guard let sharingSession else { throw SharingError.unavailable }
        try await sharingSession.receive(metadata)
    }

    func accept(url: URL) async throws {
        if sharingSession == nil { try await synchronize() }
        guard let sharingSession else { throw SharingError.unavailable }
        try await sharingSession.receive(url: url)
    }
}
