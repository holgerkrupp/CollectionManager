import CloudKit
import CollaborationCloudKit
import CollaborationCore
import CollaborationDiagnostics
import CollaborationUI
import Foundation
import Observation

@MainActor
final class CollectionShareRootResolver: CloudKitShareRootResolving {
    private(set) var plans: [UUID: CloudKitShareRootPlan] = [:]

    func setPlan(_ plan: CloudKitShareRootPlan, for collectionID: UUID) {
        plans[collectionID] = plan
    }

    func plan(for rootID: String) throws -> CloudKitShareRootPlan {
        guard let id = UUID(uuidString: rootID), let plan = plans[id] else {
            throw CloudKitShareBackendError.rootResolverUnavailable
        }
        return plan
    }

    func collectionID(for share: CKShare) -> UUID? {
        plans.first { $0.value.rootRecord.recordID.zoneID == share.recordID.zoneID }?.key
    }
}

/// UI lifecycle only. The injected pool remains the sole record transport;
/// CollectionManager's host codec owns local records, locators and permissions.
@MainActor
@Observable
final class CollectionSharingSession {
    let backend: CloudKitShareLifecycleService
    private(set) var access: [UUID: EffectiveSharingAccess] = [:]
    private(set) var unsharedRoots: Set<UUID> = []
    private(set) var invitationStatus: String?
    private(set) var invitationFailure: String?
    private let roots: CollectionShareRootResolver
    private let onAccess: @MainActor (UUID, EffectiveSharingAccess, CKShare?) async throws -> Void
    @ObservationIgnored private var invitations: InvitationAcceptanceCoordinator!
    @ObservationIgnored private var pendingMetadata: [CKRecord.ID: CKShare.Metadata] = [:]
    @ObservationIgnored private var pendingURLs: Set<URL> = []

    init(
        configuration: CollaborationConfiguration,
        pool: any CloudKitShareSyncControlling,
        onAccess: @escaping @MainActor (UUID, EffectiveSharingAccess, CKShare?) async throws -> Void,
        onAccepted: @escaping @MainActor (CKShare) async throws -> Void,
        onPreparing: @escaping @MainActor (UUID) async throws -> Void = { _ in }
    ) {
        let roots = CollectionShareRootResolver()
        self.roots = roots
        self.onAccess = onAccess
        self.backend = CloudKitShareLifecycleService(configuration: configuration, rootResolver: roots, syncEngines: pool)
        backend.onPreparingShare = { rootID in
            guard let id = UUID(uuidString: rootID) else { throw CloudKitShareBackendError.rootResolverUnavailable }
            try await onPreparing(id)
        }
        backend.onSharePrepared = { [weak self] share in
            guard let self, let id = self.roots.collectionID(for: share) else {
                throw CloudKitShareBackendError.rootResolverUnavailable
            }
            try await self.persistAccess(Self.authoritativeAccess(for: share), share: share, collectionID: id)
        }
        backend.onShareAccepted = onAccepted
        backend.onSharedDatabaseFetchResult = { [weak self] failure in
            if let failure {
                self?.invitationFailure = Self.message(for: failure)
                self?.invitationStatus = "Invitation accepted. Collection download needs another sync."
            } else {
                self?.invitationStatus = "Invitation accepted. Check the library for the downloaded collection."
            }
        }
        let backend = self.backend
        invitations = InvitationAcceptanceCoordinator(containerIdentifier: configuration.containerIdentifier) { metadata in
            try await backend.accept(metadata)
        }
    }

    func setPlan(_ plan: CloudKitShareRootPlan, for collectionID: UUID) {
        roots.setPlan(plan, for: collectionID)
    }

    /// A missing server share permits a first invitation only for a known
    /// locally-owned root. A shared database location never grants edit access.
    func canInvite(collectionID: UUID) -> Bool {
        guard let plan = roots.plans[collectionID] else { return false }
        return access[collectionID]?.canManageShare == true ||
            (unsharedRoots.contains(collectionID) && plan.rootRecord.recordID.zoneID.ownerName == CKCurrentUserDefaultName)
    }

    @discardableResult
    func refresh(collectionID: UUID) async throws -> CKShare? {
        let share = try await backend.existingShare(rootID: collectionID.uuidString)
        if let share {
            unsharedRoots.remove(collectionID)
            try await persistAccess(Self.authoritativeAccess(for: share), share: share, collectionID: collectionID)
        } else {
            let joined = roots.plans[collectionID]?.rootRecord.recordID.zoneID.ownerName != CKCurrentUserDefaultName
            if joined {
                // Confirmed absence fails closed without deleting local data.
                let unavailable = EffectiveSharingAccess(level: .unavailable, source: .unavailable)
                try await onAccess(collectionID, unavailable, nil)
                access[collectionID] = unavailable
                unsharedRoots.remove(collectionID)
            } else {
                unsharedRoots.insert(collectionID)
                access.removeValue(forKey: collectionID)
            }
        }
        return share
    }

    private func persistAccess(_ value: EffectiveSharingAccess, share: CKShare, collectionID: UUID) async throws {
        try await onAccess(collectionID, value, share)
        access[collectionID] = value
        unsharedRoots.remove(collectionID)
    }

    static func authoritativeAccess(for share: CKShare) -> EffectiveSharingAccess {
        guard let participant = share.currentUserParticipant,
              participant.acceptanceStatus == .accepted else {
            return EffectiveSharingAccess(level: .unavailable, source: .unavailable)
        }
        let level: AccessLevel
        if participant.role == .owner { level = .owner }
        else {
            switch participant.permission {
            case .readWrite: level = .editor
            case .readOnly: level = .viewer
            default: level = .unavailable
            }
        }
        return EffectiveSharingAccess(level: level, source: .cloudKitShare)
    }

    func leave(collectionID: UUID) async throws {
        try await backend.leaveSharing(rootID: collectionID.uuidString)
        let unavailable = EffectiveSharingAccess(level: .unavailable, source: .unavailable)
        try await onAccess(collectionID, unavailable, nil)
        access[collectionID] = unavailable
        unsharedRoots.remove(collectionID)
    }

    func storesDidLoad() async {
        let results = await invitations.storesDidLoad()
        record(results)
    }

    func receive(_ metadata: CKShare.Metadata) async throws {
        // The package deduplicates deliveries. Keep failed ready-state
        // deliveries here too: its pre-store queue only retains queued failures.
        pendingMetadata[metadata.share.recordID] = metadata
        do {
            let result = try await invitations.receive(metadata)
            switch result {
            case .accepted:
                pendingMetadata.removeValue(forKey: metadata.share.recordID)
                invitationStatus = "Invitation accepted. The collection is downloading."
                invitationFailure = nil
            case .duplicate:
                invitationStatus = "This invitation was already received. Check the library for download status."
            case .queuedUntilStoresLoad:
                invitationStatus = "Invitation waiting for the library to open."
            }
        } catch {
            pendingMetadata[metadata.share.recordID] = metadata
            invitationFailure = Self.message(for: error)
            throw error
        }
    }

    func receive(url: URL) async throws {
        guard InvitationAcceptanceCoordinator.isCloudShareURL(url),
              url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(), host == "icloud.com" || host.hasSuffix(".icloud.com") else {
            throw SharingError.invalidInvitation
        }
        pendingURLs.insert(url)
        do {
            let metadata = try await InvitationAcceptanceCoordinator.resolveMetadata(for: url, containerIdentifier: backend.configuration.containerIdentifier)
            try await receive(metadata)
            pendingURLs.remove(url)
        } catch {
            invitationFailure = Self.message(for: error)
            throw error
        }
    }

    func retryInvitations() async {
        record(await invitations.processPendingInvitations())
        for metadata in Array(pendingMetadata.values) {
            do { try await receive(metadata) } catch { /* retained for explicit retry */ }
        }
        for url in Array(pendingURLs) {
            do { try await receive(url: url) } catch { /* retained for explicit retry */ }
        }
    }

    private func record(_ results: [InvitationProcessingResult]) {
        for result in results {
            switch result.outcome {
            case .accepted:
                pendingMetadata = pendingMetadata.filter { $0.key.recordName != result.key.shareRecordName || $0.key.zoneID.zoneName != result.key.ownerZoneName }
                invitationStatus = "Invitation accepted. The collection is downloading."
                invitationFailure = nil
            case .duplicate:
                invitationStatus = "This invitation was already received. Check the library for download status."
            case .failed(let failure): invitationFailure = Self.message(for: failure)
            }
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? SharingError { return error.localizedDescription }
        if let error = error as? CollectionCodecError { return error.localizedDescription }
        if let error = error as? RepositoryError { return error.localizedDescription }
        let failure = (error as? CollaborationFailure) ??
            (error as? any CollaborationFailureReporting)?.collaborationFailure ??
            CollaborationErrorClassifier.classify(error)
        switch failure {
        case .noAccount: return "Sign in to iCloud and try again."
        case .restricted: return "This account cannot perform this sharing action."
        case .wrongContainer, .wrongEnvironment: return "This invitation does not match this version of Collection Manager."
        case .quotaExceeded: return "Your iCloud storage is full. Free some space and try again."
        case .conflict: return "Sharing changed on another device. Refresh and try again."
        case .revokedAccess, .notInvited: return "This invitation is unavailable. Ask the owner to check access."
        default: return "iCloud sharing is temporarily unavailable. Check your connection and try again."
        }
    }
}
