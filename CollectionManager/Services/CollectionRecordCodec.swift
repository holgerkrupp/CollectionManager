@preconcurrency import CloudKit
import CollaborationCloudKit
import CollaborationCore
import CollaborationDiagnostics
import CollaborationSwiftData
import CryptoKit
import Foundation
import SwiftData

enum CollectionCodecError: LocalizedError, Sendable {
    case accountPartitionMismatch
    case routingUnavailable
    case malformedRecord
    case missingRoot
    case handoffIncomplete
    case invalidPageSize
    case legacyReconciliationRequired
    var errorDescription: String? {
        switch self {
        case .accountPartitionMismatch: String(localized: "This library belongs to a different iCloud account. Sign in with the previous account to resume collaboration; your local library has been preserved.")
        case .routingUnavailable: String(localized: "The collection’s iCloud location is not available yet. Reconnect to iCloud and retry.")
        case .malformedRecord: String(localized: "An iCloud record could not be read safely. Your pending changes have been retained.")
        case .missingRoot: String(localized: "The shared collection has not finished importing. Retry when iCloud is available.")
        case .handoffIncomplete: String(localized: "Collaboration setup has not finished. Retry to resume it safely.")
        case .legacyReconciliationRequired: String(localized: "Some older local records could not be confirmed in iCloud. Their recoverable snapshots have been preserved; review migration recovery before completing collaboration setup.")
        case .invalidPageSize: String(localized: "The requested sync page size is invalid.")
        }
    }
}

struct CollectionLegacyCandidate: Identifiable, Sendable {
    let id: UUID
    let collectionID: UUID
    let recordName: String
    let recordType: String
    let title: String
    let canUpload: Bool
}

/// SwiftData models and contexts stay on this actor. CKRecords crossing the
/// boundary are immutable snapshots; no model instance leaves this executor.
actor CollectionRecordCodec: ModelActor, DurableSwiftDataRecordCodec {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let containerIdentifier: String
    nonisolated let environment: CollaborationEnvironment
    nonisolated let accountPartitionIdentifier: String
    nonisolated let partition: String
    nonisolated let graphPartition: String
    private let writeCoordinator: StoreWriteCoordinator
    private var operationDepth = 0
    private var operationSnapshot: StoreWriteCoordinator.Snapshot?
    private var inFlight: [String: UUID] = [:]
    private var persistenceFailure: (() throws -> Void)?
    private var eventFailureDiagnostic: String?

    init(modelContainer: ModelContainer, containerIdentifier: String, environment: CollaborationEnvironment, accountPartitionIdentifier: String) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelContainer = modelContainer
        writeCoordinator = .forContainer(modelContainer)
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.containerIdentifier = containerIdentifier
        self.environment = environment
        self.accountPartitionIdentifier = accountPartitionIdentifier
        graphPartition = Self.digest([containerIdentifier, environment.rawValue])
        partition = Self.digest([containerIdentifier, environment.rawValue, accountPartitionIdentifier])
    }

    nonisolated private static func digest(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func setPersistenceFailureForTesting(_ failure: (() throws -> Void)?) { persistenceFailure = failure }

    /// Nested delegate calls retain the snapshot captured before the outer read.
    private func beginOperation() {
        if operationDepth == 0 { operationSnapshot = writeCoordinator.snapshot() }
        operationDepth += 1
    }

    private func endOperation() {
        operationDepth -= 1
        if operationDepth == 0 {
            if modelContext.hasChanges { modelContext.rollback() }
            operationSnapshot = nil
        }
    }

    private func commit() throws {
        do {
            try persistenceFailure?()
            let changed = StoreWriteCoordinator.changedCollections(in: modelContext)
            let committed = try writeCoordinator.commit(expected: operationSnapshot, changedCollections: changed) {
                try modelContext.save()
            }
            // Do not bless unrelated scopes that changed while this operation read.
            for id in changed { operationSnapshot?[id] = committed[id] }
        } catch {
            let failure = error as NSError
            eventFailureDiagnostic = "Local commit: \(failure.domain) (\(failure.code))"
            modelContext.rollback()
            throw RepositoryError.saveFailed
        }
    }

    private func states() throws -> [CollectionTransportState] {
        let key = partition
        return try modelContext.fetch(FetchDescriptor<CollectionTransportState>(predicate: #Predicate { $0.partition == key }))
    }

    private func state(_ scope: CollaborationDatabaseScope) throws -> CollectionTransportState {
        if let existing = try states().first(where: { $0.scope == scope.rawValue }) { return existing }
        let created = CollectionTransportState(partition: partition, scope: scope.rawValue)
        modelContext.insert(created)
        return created
    }

    private func zones() throws -> [CollectionZone] {
        let key = partition
        return try modelContext.fetch(FetchDescriptor<CollectionZone>(predicate: #Predicate { $0.partition == key }))
    }

    private func outgoing(_ scope: CollaborationDatabaseScope? = nil) throws -> [CollectionOutgoingSnapshot] {
        let key = partition
        let descriptor: FetchDescriptor<CollectionOutgoingSnapshot>
        if let scope {
            let raw = scope.rawValue
            descriptor = FetchDescriptor(predicate: #Predicate { $0.partition == key && $0.scope == raw && ($0.operation == "save" || $0.operation == "delete") }, sortBy: [SortDescriptor(\.createdAt)])
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.partition == key && ($0.operation == "save" || $0.operation == "delete") }, sortBy: [SortDescriptor(\.createdAt)])
        }
        return try modelContext.fetch(descriptor)
    }

    private func baselineRows(for id: CKRecord.ID, scope: CollaborationDatabaseScope) throws -> [CollectionOutgoingSnapshot] {
        let key = partition, raw = scope.rawValue, name = id.recordName, owner = id.zoneID.ownerName, zone = id.zoneID.zoneName
        return try modelContext.fetch(FetchDescriptor<CollectionOutgoingSnapshot>(predicate: #Predicate { $0.partition == key && $0.scope == raw && $0.zoneName == zone && $0.ownerName == owner && $0.recordName == name && $0.operation == "baseline" }))
    }

    private func identity(_ id: CKRecord.ID, scope: CollaborationDatabaseScope) -> String {
        [scope.rawValue, id.zoneID.ownerName, id.zoneID.zoneName, id.recordName].map { "\($0.utf8.count):\($0)" }.joined()
    }

    private func rowID(_ row: CollectionOutgoingSnapshot) -> CKRecord.ID {
        CKRecord.ID(recordName: row.recordName, zoneID: CKRecordZone.ID(zoneName: row.zoneName, ownerName: row.ownerName))
    }

    private func claimGraph() throws {
        let graph = graphPartition
        let owners = try modelContext.fetch(FetchDescriptor<CollectionTransportOwner>(predicate: #Predicate { $0.graphPartition == graph }))
        guard owners.allSatisfy({ $0.accountPartition == partition }) else { throw CollectionCodecError.accountPartitionMismatch }
        if owners.isEmpty { modelContext.insert(CollectionTransportOwner(graphPartition: graph, accountPartition: partition)) }
    }

    func beginHandoff(legacyState: Data? = nil) throws {
        beginOperation()
        defer { endOperation() }

        try claimGraph()
        for scope in [CollaborationDatabaseScope.private, .shared] {
            let value = try state(scope)
            if value.handoffStage == "pending" {
                value.legacyState = legacyState
                value.handoffStage = "journaled"
            }
        }
        try commit()
    }

    func handoffStatus() throws -> String {
        beginOperation()
        defer { endOperation() }

        let statuses = try states().map(\.handoffStage)
        if statuses.count == 2 && statuses.allSatisfy({ $0 == "complete" }) { return "complete" }
        if statuses.contains("journaled") { return "journaled" }
        if statuses.contains("reconciling") { return "reconciling" }
        return "pending"
    }

    func completeHandoff() throws {
        beginOperation()
        defer { endOperation() }

        guard try handoffStatus() == "reconciling" || handoffStatus() == "complete" else { throw CollectionCodecError.handoffIncomplete }
        let eligible = try eligibleCollectionIDs()
        guard try outgoing().filter({ eligible.contains($0.collectionID) && ($0.operation == "save" || $0.operation == "delete") }).isEmpty else { throw CollectionCodecError.handoffIncomplete }
        guard try first(FetchDescriptor<SyncMutationRecord>(predicate: #Predicate { eligible.contains($0.collectionID) })) == nil else { throw CollectionCodecError.handoffIncomplete }
        guard try unreconciledBaselineCount() == 0 else { throw CollectionCodecError.legacyReconciliationRequired }
        for value in try states() { value.handoffStage = "complete" }
        try commit()
    }

    func registerCollection(collectionID: UUID, zoneID: CKRecordZone.ID, scope: CollaborationDatabaseScope, shareRecordName: String? = nil, role: CollectionMemberRole) throws {
        beginOperation()
        defer { endOperation() }

        guard !zoneID.ownerName.isEmpty, !zoneID.zoneName.isEmpty else { throw CollectionCodecError.routingUnavailable }
        let value: CollectionZone
        let matchingZones = try zones().filter { $0.collectionID == collectionID }
        if let existing = matchingZones.first(where: { $0.scope == "shared" }) ?? matchingZones.first {
            // A joined collection wins over a legacy private shadow, never the inverse.
            if existing.scope == "shared" && scope == .private { return }
            if existing.scope == "shared", scope == .shared,
               (existing.ownerName != zoneID.ownerName || existing.zoneName != zoneID.zoneName) {
                throw CollectionCodecError.routingUnavailable
            }
            value = existing
        } else {
            value = CollectionZone(partition: partition, collectionID: collectionID, scope: scope.rawValue, zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
            modelContext.insert(value)
        }
        value.scope = scope.rawValue; value.zoneName = zoneID.zoneName; value.ownerName = zoneID.ownerName
        value.shareRecordName = shareRecordName ?? value.shareRecordName
        value.roleRawValue = role.rawValue; value.authoritative = true; value.active = true
        try applyAccess(collectionID: collectionID, role: role)
        try commit()
    }

    func updateAccess(collectionID: UUID, role: CollectionMemberRole) throws {
        beginOperation()
        defer { endOperation() }

        guard let zone = try zones().first(where: { $0.collectionID == collectionID }) else { throw CollectionCodecError.routingUnavailable }
        zone.roleRawValue = role.rawValue; zone.authoritative = true
        try applyAccess(collectionID: collectionID, role: role)
        try commit()
    }

    func deactivateSharedCollection(collectionID: UUID) throws {
        beginOperation()
        defer { endOperation() }

        guard let zone = try zones().first(where: { $0.collectionID == collectionID }), zone.scope == "shared" else { return }
        zone.active = false; zone.roleRawValue = "viewer"; zone.authoritative = true
        try applyAccess(collectionID: collectionID, role: .viewer)
        try commit()
    }

    private func applyAccess(collectionID: UUID, role: CollectionMemberRole) throws {
        let id = collectionID
        let members = try modelContext.fetch(FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == id })).filter { !$0.participantID.hasPrefix("share:") }
        if members.isEmpty { modelContext.insert(CollectionMemberRecord(collectionID: id, participantID: "cloud", role: role)) }
        else { for member in members where member.roleRawValue != role.rawValue { member.roleRawValue = role.rawValue; member.updatedAt = .now } }
    }

    /// Only an explicit new-collection transaction authorizes creating a zone.
    /// A missing legacy zone must never be recreated as automatic recovery.
    func authorizedNewPrivateZones() throws -> [CKRecordZone.ID] {
        beginOperation()
        defer { endOperation() }

        let intents = try modelContext.fetch(FetchDescriptor<SyncMutationRecord>(predicate: #Predicate { $0.operation == "createCollection" }))
        return try intents.map { intent in
            let zone = try locator(for: intent.collectionID)
            guard zone.scope == "private", zone.roleRawValue == "owner" else { throw RepositoryError.permissionDenied }
            return CKRecordZone.ID(zoneName: zone.zoneName, ownerName: zone.ownerName)
        }
    }

    func knownZones(in scope: CollaborationDatabaseScope) throws -> [CKRecordZone.ID] {
        beginOperation()
        defer { endOperation() }

        let all = try zones()
        let joinedIDs = Set(all.filter { $0.scope == "shared" }.map(\.collectionID))
        return all.filter { $0.scope == scope.rawValue && $0.active && (scope != .private || !joinedIDs.contains($0.collectionID)) }.map { CKRecordZone.ID(zoneName: $0.zoneName, ownerName: $0.ownerName) }
    }

    private func locator(for collectionID: UUID) throws -> CollectionZone {
        let matching = try zones().filter { $0.collectionID == collectionID }
        if let zone = matching.first(where: { $0.scope == "shared" }) ?? matching.first { return zone }
        let id = collectionID
        let members = try modelContext.fetch(FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == id }))
        let ownerDeletion = try first(FetchDescriptor<SyncMutationRecord>(predicate: #Predicate { $0.collectionID == id && $0.recordType == "Collection" && $0.operation == "delete" })) != nil
        guard members.first(where: { !$0.participantID.hasPrefix("share:") })?.roleRawValue == "owner" || ownerDeletion else { throw CollectionCodecError.routingUnavailable }
        let created = CollectionZone(partition: partition, collectionID: id, scope: "private", zoneName: "collection-\(id.uuidString)", ownerName: CKCurrentUserDefaultName)
        created.roleRawValue = "owner"; created.authoritative = true
        modelContext.insert(created)
        return created
    }

    func sharePlans() throws -> [CloudKitShareRootPlan] {
        beginOperation()
        defer { endOperation() }

        let collections = try modelContext.fetch(FetchDescriptor<CollectionRecord>())
        let plans = try collections.map { value in
            let zone = try locator(for: value.id)
            let recordID = CKRecord.ID(recordName: value.id.uuidString, zoneID: CKRecordZone.ID(zoneName: zone.zoneName, ownerName: zone.ownerName))
            let record = try encodeModel(value, id: recordID, scope: CollaborationDatabaseScope(rawValue: zone.scope) ?? .private)
            return CloudKitShareRootPlan(rootID: value.id.uuidString, title: value.name, rootRecord: record, topology: .hierarchy)
        }
        try commit()
        return plans
    }

    func loadState(for scope: CollaborationDatabaseScope) throws -> Data? {
        beginOperation()
        defer { endOperation() }
        return try states().first(where: { $0.scope == scope.rawValue })?.engineState
    }
    func saveState(_ data: Data, for scope: CollaborationDatabaseScope) throws {
        beginOperation()
        defer { endOperation() }

        let value = try state(scope)
        value.engineState = data
        value.lastFailure = nil
        try commit()
        eventFailureDiagnostic = nil
    }
    func reportStatePersistenceFailure(_ failure: CollaborationFailure, for scope: CollaborationDatabaseScope) {
        beginOperation()
        defer { endOperation() }

        do { try state(scope).lastFailure = eventFailureDiagnostic ?? "Collaboration progress could not be committed."; try commit() }
        catch { /* Preserve the previous durable state; the pool is already stopped. */ }
    }

    private func eligibleCollectionIDs() throws -> Set<UUID> {
        var roles: [UUID: String] = [:]
        for member in try modelContext.fetch(FetchDescriptor<CollectionMemberRecord>()) where !member.participantID.hasPrefix("share:") { roles[member.collectionID] = member.roleRawValue }
        // An owner delete has already passed the repository authorization check.
        for deletion in try modelContext.fetch(FetchDescriptor<SyncMutationRecord>(predicate: #Predicate { $0.recordType == "Collection" && $0.operation == "delete" })) where roles[deletion.collectionID] == nil { roles[deletion.collectionID] = "owner" }
        let allZones = try zones()
        for zone in allZones where zone.scope != "shared" { roles[zone.collectionID] = zone.roleRawValue }
        for zone in allZones where zone.scope == "shared" { roles[zone.collectionID] = zone.roleRawValue }
        return Set(roles.compactMap { $0.value == "owner" || $0.value == "editor" ? $0.key : nil })
    }

    func hasEligibleUnstagedMutations() throws -> Bool {
        beginOperation()
        defer { endOperation() }

        let eligible = try eligibleCollectionIDs()
        let covered = Set(try outgoing().flatMap { try JSONDecoder().decode([UUID].self, from: $0.mutationIDs) })
        return try first(FetchDescriptor<SyncMutationRecord>(predicate: #Predicate { eligible.contains($0.collectionID) && !covered.contains($0.id) })) != nil
    }

    func unreconciledBaselineCount() throws -> Int {
        beginOperation()
        defer { endOperation() }

        let key = partition
        return try modelContext.fetchCount(FetchDescriptor<CollectionOutgoingSnapshot>(predicate: #Predicate { $0.partition == key && $0.operation == "baseline" }))
    }

    /// Bounded review data, never diagnostics. The user sees which legacy
    /// candidates were not confirmed in the unchanged server graph.
    func legacyCandidates(limit: Int = 50, offset: Int = 0) throws -> [CollectionLegacyCandidate] {
        beginOperation()
        defer { endOperation() }

        guard limit > 0, offset >= 0 else { throw CollectionCodecError.invalidPageSize }
        let key = partition, eligible = try eligibleCollectionIDs()
        var descriptor = FetchDescriptor<CollectionOutgoingSnapshot>(predicate: #Predicate { $0.partition == key && $0.operation == "baseline" }, sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = min(limit, 100); descriptor.fetchOffset = offset
        return try modelContext.fetch(descriptor).map { row in
            guard let archive = row.recordArchive, let record = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: archive) else { throw CollectionCodecError.malformedRecord }
            let canonicalScope = try locator(for: row.collectionID).scope
            return CollectionLegacyCandidate(id: row.id, collectionID: row.collectionID, recordName: row.recordName, recordType: row.recordType, title: record["title"] as? String ?? record["name"] as? String ?? row.recordType, canUpload: eligible.contains(row.collectionID) && canonicalScope == row.scope)
        }
    }

    /// Called only after explicit user review; never from automatic startup or
    /// retry. Stage the current local value, retaining the recoverable baseline.
    func authorizeBaselineUpload(snapshotID: UUID) throws {
        beginOperation()
        defer { endOperation() }

        try claimGraph()
        let key = partition
        guard let row = try first(FetchDescriptor<CollectionOutgoingSnapshot>(predicate: #Predicate { $0.partition == key && $0.id == snapshotID && $0.operation == "baseline" })), let scope = CollaborationDatabaseScope(rawValue: row.scope) else { throw CollectionCodecError.malformedRecord }
        let canonicalScope = try locator(for: row.collectionID).scope
        guard try eligibleCollectionIDs().contains(row.collectionID), canonicalScope == row.scope else { throw RepositoryError.permissionDenied }
        guard let model = try domainModel(recordName: row.recordName, type: row.recordType, collectionID: row.collectionID) else { throw CollectionCodecError.missingRoot }
        try stage(.save(encodeModel(model, id: rowID(row), scope: scope)), mutationIDs: [], scope: scope)
        row.operation = "baselineReconciled"
        try commit()
    }

    /// Existing local intent is already atomic with domain edits. Capture payloads
    /// and covered generation IDs before giving the engine anything to send.
    func stageRepositoryMutations(limit: Int = 400) throws -> [CollaborationDatabaseScope: [CloudKitRecordChange]] {
        beginOperation()
        defer { endOperation() }

        guard limit > 0 else { throw CollectionCodecError.invalidPageSize }
        try claimGraph()
        let covered = Set(try outgoing().flatMap { try JSONDecoder().decode([UUID].self, from: $0.mutationIDs) })
        let eligible = try eligibleCollectionIDs()
        var descriptor = FetchDescriptor<SyncMutationRecord>(predicate: #Predicate { eligible.contains($0.collectionID) && !covered.contains($0.id) }, sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = limit
        let batch = try modelContext.fetch(descriptor)
        var result: [CollaborationDatabaseScope: [CloudKitRecordChange]] = [:]
        for mutation in batch {
            let zone = try locator(for: mutation.collectionID)
            guard zone.roleRawValue == "owner" || zone.roleRawValue == "editor" else { continue }
            let scope = CollaborationDatabaseScope(rawValue: zone.scope) ?? .private
            let id = CKRecord.ID(recordName: mutation.recordName, zoneID: CKRecordZone.ID(zoneName: zone.zoneName, ownerName: zone.ownerName))
            let change: CloudKitRecordChange
            if mutation.operation == "delete" { change = .delete(id) }
            else if let model = try domainModel(recordName: mutation.recordName, type: mutation.recordType, collectionID: mutation.collectionID) {
                change = .save(try encodeModel(model, id: id, scope: scope))
            } else {
                // An unsent create/edit followed by a delete must not become a
                // zombie upload. Journal the deletion with the old generation.
                change = .delete(id)
            }
            try stage(change, mutationIDs: [mutation.id], scope: scope)
            result[scope, default: []].append(change)
        }
        try commit()
        return [CollaborationDatabaseScope.private: try pendingLocalChanges(in: .private), .shared: try pendingLocalChanges(in: .shared)]
    }

    func stageLocalChanges(_ changes: [CloudKitRecordChange], advancingTo historyCursor: Data?, in scope: CollaborationDatabaseScope) throws {
        beginOperation()
        defer { endOperation() }

        for change in changes { try stage(change, mutationIDs: [], scope: scope) }
        try state(scope).historyCursor = historyCursor
        try commit()
    }

    private func stage(_ change: CloudKitRecordChange, mutationIDs: [UUID], scope: CollaborationDatabaseScope, baseline: Bool = false, forceQuarantine: Bool = false) throws {
        let id = change.recordID
        let row = CollectionOutgoingSnapshot(partition: partition, scope: scope.rawValue, zoneName: id.zoneID.zoneName, ownerName: id.zoneID.ownerName, recordName: id.recordName)
        row.collectionID = try self.collectionID(for: id.zoneID, scope: scope)
        row.mutationIDs = try JSONEncoder().encode(mutationIDs)
        switch change {
        case .save(let record):
            row.recordType = record.recordType
            row.recordArchive = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
            if let asset = record["imageAsset"] as? CKAsset {
                guard let file = asset.fileURL else { throw CollectionCodecError.malformedRecord }
                row.assetData = try Data(contentsOf: file)
                let assetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CollectionManager-sync-assets", isDirectory: true).path + "/"
                if file.path.hasPrefix(assetDirectory) && file.lastPathComponent.hasPrefix("encoded-") { try? FileManager.default.removeItem(at: file) }
            }
        case .delete:
            row.operation = "delete"
        }
        if baseline {
            row.operation = "baseline"
            if !forceQuarantine, case .save(let record) = change, let confirmed = try systemState(for: id, scope: scope) {
                row.operation = "baselineReconciled"
                let localTime = record["updatedAt"] as? Date ?? record["timestamp"] as? Date ?? .distantPast
                if !(try hasLocalIntent(id, scope: scope)), localTime > (confirmed.serverModifiedAt ?? .distantFuture) {
                    try stage(change, mutationIDs: [], scope: scope)
                }
            }
        }
        modelContext.insert(row)
    }

    private func restore(_ row: CollectionOutgoingSnapshot) throws -> CloudKitRecordChange {
        if row.operation == "delete" { return .delete(rowID(row)) }
        guard let data = row.recordArchive, let record = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data) else { throw CollectionCodecError.malformedRecord }
        if let asset = row.assetData { record["imageAsset"] = try materializeAsset(asset, identity: "snapshot-" + row.id.uuidString) }
        return .save(record)
    }

    func pendingLocalChanges(in scope: CollaborationDatabaseScope) throws -> [CloudKitRecordChange] {
        beginOperation()
        defer { endOperation() }

        let key = partition, raw = scope.rawValue
        let eligible = try eligibleCollectionIDs()
        var descriptor = FetchDescriptor<CollectionOutgoingSnapshot>(predicate: #Predicate { $0.partition == key && $0.scope == raw && eligible.contains($0.collectionID) && ($0.operation == "save" || $0.operation == "delete") }, sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 400
        var seen = Set<String>(), result: [CloudKitRecordChange] = []
        var assetBytes = 0
        for row in try modelContext.fetch(descriptor) {
            let identity = identity(rowID(row), scope: scope)
            guard seen.insert(identity).inserted else { continue }
            let bytes = row.assetData?.count ?? 0
            if !result.isEmpty && (result.count >= 100 || assetBytes + bytes > 16 * 1024 * 1024) { break }
            result.append(try restore(row)); assetBytes += bytes
        }
        return result
    }

    /// Materialize every save before returning a batch. Returning nil from a
    /// record-provider closure can remove that engine save; a failed host read
    /// must instead leave the entire batch pending for a later retry/restart.
    func prepareSendBatch(_ pending: [CKSyncEngine.PendingRecordZoneChange], in scope: CollaborationDatabaseScope) throws -> CKSyncEngine.RecordZoneChangeBatch? {
        beginOperation()
        defer { endOperation() }

        var saving: [CKRecord] = [], deleting: [CKRecord.ID] = []
        let eligible = try eligibleCollectionIDs()
        let allowed = try pending.filter { change in
            let id: CKRecord.ID
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID): id = recordID
            @unknown default: throw CollectionCodecError.malformedRecord
            }
            return try eligible.contains(collectionID(for: id.zoneID, scope: scope))
        }
        for change in allowed.prefix(100) {
            switch change {
            case .saveRecord(let id):
                guard let record = try record(for: id, in: scope) else { throw CollectionCodecError.malformedRecord }
                saving.append(record)
            case .deleteRecord(let id): deleting.append(id)
            @unknown default: throw CollectionCodecError.malformedRecord
            }
        }
        guard !saving.isEmpty || !deleting.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: saving, recordIDsToDelete: deleting)
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        beginOperation()
        defer { endOperation() }

        let scope: CollaborationDatabaseScope = syncEngine.database.databaseScope == .shared ? .shared : .private
        do {
            return try prepareSendBatch(syncEngine.state.pendingRecordZoneChanges.filter(context.options.scope.contains), in: scope)
        } catch {
            reportStatePersistenceFailure(.notYetAvailable, for: scope)
            return nil
        }
    }

    func record(for recordID: CKRecord.ID, in scope: CollaborationDatabaseScope) throws -> CKRecord? {
        beginOperation()
        defer { endOperation() }

        guard let row = try outgoing(scope).first(where: { rowID($0) == recordID && $0.operation == "save" }) else { return nil }
        guard case .save(let record) = try restore(row) else { return nil }
        inFlight[identity(recordID, scope: scope)] = row.id
        return record
    }

    /// One bounded page is committed with its cursor. A crash before commit
    /// repeats that page; a crash after commit resumes at the next page.
    func bootstrapPage(limit: Int = 400) throws -> Bool {
        beginOperation()
        defer { endOperation() }

        guard limit > 0 else { throw CollectionCodecError.invalidPageSize }
        try claimGraph()
        let progress = try state(.private)
        guard progress.handoffStage != "pending" else { throw CollectionCodecError.handoffIncomplete }
        if progress.handoffStage != "journaled" { return false }
        let offset = progress.bootstrapOffset
        let page: [any PersistentModel]
        switch progress.bootstrapModelIndex {
        case 0: page = try pageOf(CollectionRecord.self, sort: SortDescriptor(\.id), offset: offset, limit: limit)
        case 1: page = try pageOf(ItemRecord.self, sort: SortDescriptor(\.id), offset: offset, limit: limit)
        case 2: page = try pageOf(EventRecord.self, sort: SortDescriptor(\.id), offset: offset, limit: limit)
        case 3: page = try pageOf(ItemRatingRecord.self, sort: SortDescriptor(\.id), offset: offset, limit: limit)
        case 4: page = try pageOf(ItemCommentRecord.self, sort: SortDescriptor(\.id), offset: offset, limit: limit)
        default:
            for value in try states() { value.handoffStage = "reconciling" }
            try commit(); return false
        }
        for model in page {
            let info = try modelIdentity(model)
            let zone = try locator(for: info.collectionID)
            guard zone.roleRawValue == "owner" || zone.roleRawValue == "editor" else { continue }
            let scope = CollaborationDatabaseScope(rawValue: zone.scope) ?? .private
            let id = CKRecord.ID(recordName: info.name, zoneID: CKRecordZone.ID(zoneName: zone.zoneName, ownerName: zone.ownerName))
            if try baselineRows(for: id, scope: scope).isEmpty {
                try stage(.save(encodeModel(model, id: id, scope: scope)), mutationIDs: [], scope: scope, baseline: true)
            }
        }
        if page.count < limit { progress.bootstrapModelIndex += 1; progress.bootstrapOffset = 0 }
        else { progress.bootstrapOffset += page.count }
        try commit()
        return true
    }

    private func pageOf<T: PersistentModel>(_ type: T.Type, sort: SortDescriptor<T>, offset: Int, limit: Int) throws -> [T] {
        var descriptor = FetchDescriptor<T>(sortBy: [sort]); descriptor.fetchOffset = offset; descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    private func modelIdentity(_ model: any PersistentModel) throws -> (collectionID: UUID, name: String, type: String) {
        switch model {
        case let value as CollectionRecord: (value.id, value.id.uuidString, "Collection")
        case let value as ItemRecord: (value.collectionID, value.id.uuidString, "CollectionItem")
        case let value as EventRecord: (value.collectionID, value.id.uuidString, "CollectionEvent")
        case let value as ItemRatingRecord: (value.collectionID, "\(value.itemID.uuidString)-rating-\(value.participantID)", "CollectionItemRating")
        case let value as ItemCommentRecord: (value.collectionID, value.id.uuidString, "CollectionItemComment")
        default: throw CollectionCodecError.malformedRecord
        }
    }

    private func first<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> T? {
        var limited = descriptor; limited.fetchLimit = 1
        return try modelContext.fetch(limited).first
    }

    private func domainModel(recordName: String, type: String, collectionID: UUID) throws -> (any PersistentModel)? {
        let collection = collectionID
        if type == "CollectionItemRating" {
            guard recordName.count >= 44, let item = UUID(uuidString: String(recordName.prefix(36))), recordName.dropFirst(36).hasPrefix("-rating-") else { throw CollectionCodecError.malformedRecord }
            let participant = String(recordName.dropFirst(44))
            return try first(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.itemID == item && $0.participantID == participant && $0.collectionID == collection }))
        }
        guard let uuid = UUID(uuidString: recordName) else { throw CollectionCodecError.malformedRecord }
        switch type {
        case "Collection": return try first(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == uuid && $0.id == collection }))
        case "CollectionItem": return try first(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.id == uuid && $0.collectionID == collection }))
        case "CollectionEvent": return try first(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.id == uuid && $0.collectionID == collection }))
        case "CollectionItemComment": return try first(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.id == uuid && $0.collectionID == collection }))
        default: throw CollectionCodecError.malformedRecord
        }
    }

    private func systemState(for id: CKRecord.ID, scope: CollaborationDatabaseScope) throws -> CollectionCloudRecordState? {
        let key = partition, name = id.recordName, owner = id.zoneID.ownerName, zone = id.zoneID.zoneName, raw = scope.rawValue
        return try modelContext.fetch(FetchDescriptor<CollectionCloudRecordState>(predicate: #Predicate { $0.partition == key && $0.scope == raw && $0.recordName == name && $0.ownerName == owner && $0.zoneName == zone })).first
    }

    private func baseRecord(type: String, id: CKRecord.ID, scope: CollaborationDatabaseScope) throws -> CKRecord {
        if let state = try systemState(for: id, scope: scope) {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: state.systemFields)
            decoder.requiresSecureCoding = true
            defer { decoder.finishDecoding() }
            guard let record = CKRecord(coder: decoder), record.recordID == id, record.recordType == type else { throw CollectionCodecError.malformedRecord }
            return record
        }
        return CKRecord(recordType: type, recordID: id)
    }

    private func remember(_ record: CKRecord, scope: CollaborationDatabaseScope) throws {
        let value = try systemState(for: record.recordID, scope: scope) ?? CollectionCloudRecordState(partition: partition, scope: scope.rawValue, zoneName: record.recordID.zoneID.zoneName, ownerName: record.recordID.zoneID.ownerName, recordName: record.recordID.recordName)
        if value.modelContext == nil { modelContext.insert(value) }
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: encoder); encoder.finishEncoding()
        value.systemFields = encoder.encodedData; value.recordType = record.recordType
        value.serverModifiedAt = record["updatedAt"] as? Date ?? record["timestamp"] as? Date
    }

    private func encodeModel(_ model: any PersistentModel, id: CKRecord.ID, scope: CollaborationDatabaseScope) throws -> CKRecord {
        let info = try modelIdentity(model)
        let record = try baseRecord(type: info.type, id: id, scope: scope)
        switch model {
        case let value as CollectionRecord:
            record["name"] = value.name as CKRecordValue; record["icon"] = value.icon as CKRecordValue; record["subtitle"] = value.subtitle as CKRecordValue; record["settingsJSON"] = value.settingsJSON as CKRecordValue; record["updatedAt"] = value.updatedAt as CKRecordValue
        case let value as ItemRecord:
            record["collectionID"] = value.collectionID.uuidString as CKRecordValue
            record["title"] = value.title as CKRecordValue; record["brand"] = value.brand as CKRecordValue; record["variant"] = value.variant as CKRecordValue; record["itemDescription"] = value.itemDescription as CKRecordValue
            record["state"] = value.stateRawValue as CKRecordValue; record["quantity"] = value.quantity as CKRecordValue; record["createdAt"] = value.createdAt as CKRecordValue; record["updatedAt"] = value.updatedAt as CKRecordValue; record["consumedAt"] = value.consumedAt as CKRecordValue?
            record["tagsJSON"] = value.tagsJSON as CKRecordValue; record["metadataJSON"] = value.metadataJSON as CKRecordValue; record["sourceSnapshotJSON"] = value.sourceSnapshotJSON as CKRecordValue?
            record["barcodeValue"] = value.barcodeValue as CKRecordValue?; record["barcodeType"] = value.barcodeType as CKRecordValue?; record["imageSystemName"] = value.imageSystemName as CKRecordValue; record["importSourceKey"] = value.importSourceKey as CKRecordValue?
            record["imageAsset"] = try value.imageData.map { try materializeAsset($0, identity: "encoded-" + UUID().uuidString) }
            record.parent = CKRecord.Reference(recordID: CKRecord.ID(recordName: info.collectionID.uuidString, zoneID: id.zoneID), action: .none)
        case let value as EventRecord:
            record["itemID"] = value.itemID.uuidString as CKRecordValue; record["timestamp"] = value.timestamp as CKRecordValue; record["type"] = value.type as CKRecordValue; record["note"] = value.note as CKRecordValue?
            record.parent = CKRecord.Reference(recordID: CKRecord.ID(recordName: info.collectionID.uuidString, zoneID: id.zoneID), action: .none)
        case let value as ItemRatingRecord:
            record["id"] = value.id.uuidString as CKRecordValue; record["itemID"] = value.itemID.uuidString as CKRecordValue; record["participantID"] = value.participantID as CKRecordValue; record["participantName"] = value.participantName as CKRecordValue; record["value"] = value.value as CKRecordValue; record["updatedAt"] = value.updatedAt as CKRecordValue
            record.parent = CKRecord.Reference(recordID: CKRecord.ID(recordName: value.itemID.uuidString, zoneID: id.zoneID), action: .none)
        case let value as ItemCommentRecord:
            record["id"] = value.id.uuidString as CKRecordValue; record["itemID"] = value.itemID.uuidString as CKRecordValue; record["participantID"] = value.participantID as CKRecordValue; record["participantName"] = value.participantName as CKRecordValue; record["text"] = value.text as CKRecordValue; record["createdAt"] = value.createdAt as CKRecordValue; record["updatedAt"] = value.updatedAt as CKRecordValue
            record.parent = CKRecord.Reference(recordID: CKRecord.ID(recordName: value.itemID.uuidString, zoneID: id.zoneID), action: .none)
        default: throw CollectionCodecError.malformedRecord
        }
        return record
    }

    private func materializeAsset(_ data: Data, identity: String) throws -> CKAsset {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CollectionManager-sync-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(identity)
        if identity.hasPrefix("snapshot-"), FileManager.default.fileExists(atPath: file.path) {
            guard try Data(contentsOf: file) == data else { throw CollectionCodecError.malformedRecord }
        } else { try data.write(to: file, options: .atomic) }
        return CKAsset(fileURL: file)
    }

    func acknowledgeSentChanges(savedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID], in scope: CollaborationDatabaseScope) throws {
        beginOperation()
        defer { endOperation() }

        for record in savedRecords { try remember(record, scope: scope); try markBaselineReconciled(record.recordID, scope: scope) }
        for id in deletedRecordIDs { try markBaselineReconciled(id, scope: scope) }
        for id in savedRecords.map(\.recordID) + deletedRecordIDs {
            let key = identity(id, scope: scope)
            for diagnostic in try failureRows(for: id, scope: scope) { modelContext.delete(diagnostic) }
            let rows = try outgoing(scope).filter { rowID($0) == id && ($0.operation == "save" || $0.operation == "delete") }
            // Deletes have no record-provider callback. Their oldest generation
            // is what the engine could have sent; newer generations stay queued.
            let sent = inFlight[key].flatMap { selected in rows.first { $0.id == selected } } ?? rows.first
            if let sent {
                let ids = Set(try JSONDecoder().decode([UUID].self, from: sent.mutationIDs))
                for mutation in try modelContext.fetch(FetchDescriptor<SyncMutationRecord>()) where ids.contains(mutation.id) { modelContext.delete(mutation) }
                modelContext.delete(sent)
            }
            inFlight.removeValue(forKey: key)
        }
        try commit()
    }

    func applyRemoteChanges(records: [CKRecord], deletedRecordIDs: [CKRecord.ID], in scope: CollaborationDatabaseScope) throws {
        beginOperation()
        defer { endOperation() }

        modelContext.author = "CollectionManager.remote"
        defer { modelContext.author = nil }
        let pending = try outgoing(scope).filter { $0.operation == "save" || $0.operation == "delete" }
        for record in records.sorted(by: { $0.recordType == "Collection" && $1.recordType != "Collection" }) {
            if try isPrivateShadow(record.recordID, scope: scope) {
                if try baselineRows(for: record.recordID, scope: scope).isEmpty {
                    try stage(.save(record), mutationIDs: [], scope: scope, baseline: true, forceQuarantine: true)
                }
                continue
            }
            try remember(record, scope: scope)
            try reconcileBaseline(record, scope: scope)
            if try pending.contains(where: { rowID($0) == record.recordID }) || hasLocalIntent(record.recordID, scope: scope) { continue }
            try apply(record, scope: scope)
        }
        for id in deletedRecordIDs {
            if try isPrivateShadow(id, scope: scope) {
                try markBaselineReconciled(id, scope: scope)
                continue
            }
            try markBaselineReconciled(id, scope: scope)
            if try pending.contains(where: { rowID($0) == id }) || hasLocalIntent(id, scope: scope) { continue }
            try applyDeletion(id, scope: scope)
        }
        try commit()
    }

    private func markBaselineReconciled(_ id: CKRecord.ID, scope: CollaborationDatabaseScope) throws {
        for row in try baselineRows(for: id, scope: scope) { row.operation = "baselineReconciled" }
    }

    private func reconcileBaseline(_ server: CKRecord, scope: CollaborationDatabaseScope) throws {
        guard try !baselineRows(for: server.recordID, scope: scope).isEmpty else { return }
        try markBaselineReconciled(server.recordID, scope: scope)
        guard !(try hasLocalIntent(server.recordID, scope: scope)) else { return }
        let collectionID = try self.collectionID(for: server.recordID.zoneID, scope: scope)
        guard try eligibleCollectionIDs().contains(collectionID), let model = try domainModel(recordName: server.recordID.recordName, type: server.recordType, collectionID: collectionID) else { return }
        let local = try encodeModel(model, id: server.recordID, scope: scope)
        let localTime = local["updatedAt"] as? Date ?? local["timestamp"] as? Date ?? .distantPast
        let serverTime = server["updatedAt"] as? Date ?? server["timestamp"] as? Date ?? .distantPast
        if localTime > serverTime { try stage(.save(local), mutationIDs: [], scope: scope) }
    }

    private func hasLocalIntent(_ id: CKRecord.ID, scope: CollaborationDatabaseScope) throws -> Bool {
        let collectionID = try self.collectionID(for: id.zoneID, scope: scope)
        let name = id.recordName
        return try first(FetchDescriptor<SyncMutationRecord>(predicate: #Predicate { $0.collectionID == collectionID && $0.recordName == name })) != nil
    }

    private func isPrivateShadow(_ id: CKRecord.ID, scope: CollaborationDatabaseScope) throws -> Bool {
        guard scope == .private, id.zoneID.zoneName.hasPrefix("collection-"),
              let collection = UUID(uuidString: String(id.zoneID.zoneName.dropFirst("collection-".count))) else { return false }
        return try zones().contains { $0.collectionID == collection && $0.scope == "shared" }
    }

    private func collectionID(for zoneID: CKRecordZone.ID, scope: CollaborationDatabaseScope) throws -> UUID {
        if let locator = try zones().first(where: { $0.zoneName == zoneID.zoneName && $0.ownerName == zoneID.ownerName && $0.scope == scope.rawValue }) { return locator.collectionID }
        guard zoneID.zoneName.hasPrefix("collection-"), let id = UUID(uuidString: String(zoneID.zoneName.dropFirst("collection-".count))) else { throw CollectionCodecError.routingUnavailable }
        if scope == .private, try zones().contains(where: { $0.collectionID == id && $0.scope == "shared" }) { return id }
        // Discovery supplies a location, never editor authority.
        let zone = CollectionZone(partition: partition, collectionID: id, scope: scope.rawValue, zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
        zone.roleRawValue = scope == .private ? "owner" : "viewer"
        zone.authoritative = scope == .private
        modelContext.insert(zone)
        return id
    }

    private func apply(_ record: CKRecord, scope: CollaborationDatabaseScope) throws {
        let collectionID = try self.collectionID(for: record.recordID.zoneID, scope: scope)
        guard try record.recordType == "Collection" || first(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == collectionID })) != nil else { throw CollectionCodecError.missingRoot }
        let uuid = UUID(uuidString: record.recordID.recordName)
        switch record.recordType {
        case "Collection":
            guard let id = uuid, id == collectionID, let name = record["name"] as? String else { throw CollectionCodecError.malformedRecord }
            let existing = try first(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == id }))
            let value = existing ?? CollectionRecord(id: id, name: name)
            if existing == nil { modelContext.insert(value) }
            let updated = record["updatedAt"] as? Date ?? .distantPast
            if existing == nil || updated >= value.updatedAt { value.name = name; value.icon = record["icon"] as? String ?? value.icon; value.subtitle = record["subtitle"] as? String ?? value.subtitle; value.settingsJSON = record["settingsJSON"] as? String ?? value.settingsJSON; value.updatedAt = updated }
            let zone = try locator(for: id)
            try applyAccess(collectionID: id, role: CollectionMemberRole(rawValue: zone.roleRawValue) ?? .viewer)
        case "CollectionItem":
            guard let id = uuid, let title = record["title"] as? String else { throw CollectionCodecError.malformedRecord }
            if let declared = record["collectionID"] as? String, declared != collectionID.uuidString { throw CollectionCodecError.malformedRecord }
            let existing = try first(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.id == id }))
            guard existing == nil || existing?.collectionID == collectionID else { throw CollectionCodecError.malformedRecord }
            let updated = record["updatedAt"] as? Date ?? .distantPast
            if let existing, existing.updatedAt > updated { return }
            let asset = try (record["imageAsset"] as? CKAsset).map { asset -> Data in guard let url = asset.fileURL else { throw CollectionCodecError.malformedRecord }; return try Data(contentsOf: url) }
            let value: ItemRecord
            if let existing { value = existing }
            else {
                let item = CollectionItem(id: id, collectionID: collectionID, title: title, brand: "", variant: "", itemDescription: "", state: ItemState(rawValue: "wanted"), quantity: 1, barcode: nil, createdAt: record["createdAt"] as? Date ?? updated, updatedAt: updated, consumedAt: nil, tags: [], metadata: [:], imageSystemName: "shippingbox.fill", imageData: nil, importSourceKey: nil)
                value = ItemRecord(from: item); modelContext.insert(value)
            }
            value.title = title; value.brand = record["brand"] as? String ?? ""; value.variant = record["variant"] as? String ?? ""; value.itemDescription = record["itemDescription"] as? String ?? ""; value.stateRawValue = record["state"] as? String ?? "wanted"; value.quantity = record["quantity"] as? Int ?? 1; value.updatedAt = updated; value.consumedAt = record["consumedAt"] as? Date
            value.tagsJSON = record["tagsJSON"] as? String ?? "[]"; value.metadataJSON = record["metadataJSON"] as? String ?? "{}"; value.sourceSnapshotJSON = record["sourceSnapshotJSON"] as? String; value.barcodeValue = record["barcodeValue"] as? String; value.barcodeType = record["barcodeType"] as? String; value.imageSystemName = record["imageSystemName"] as? String ?? value.imageSystemName; value.importSourceKey = record["importSourceKey"] as? String
            // Missing image field in an old client is not an instruction to erase it.
            if let asset { value.imageData = asset }
        case "CollectionEvent":
            guard let id = uuid, let itemID = UUID(uuidString: record["itemID"] as? String ?? "") else { throw CollectionCodecError.malformedRecord }
            if try first(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.id == id })) != nil { return }
            let value = EventRecord(itemID: itemID, collectionID: collectionID, type: record["type"] as? String ?? "unknown", note: record["note"] as? String); value.id = id; value.timestamp = record["timestamp"] as? Date ?? .distantPast; modelContext.insert(value)
        case "CollectionItemRating":
            guard let itemID = UUID(uuidString: record["itemID"] as? String ?? ""), let participant = record["participantID"] as? String, let id = UUID(uuidString: record["id"] as? String ?? "") else { throw CollectionCodecError.malformedRecord }
            let existing = try first(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.itemID == itemID && $0.participantID == participant && $0.collectionID == collectionID }))
            let updated = record["updatedAt"] as? Date ?? .distantPast
            if let existing, existing.updatedAt > updated { return }
            let value = existing ?? ItemRatingRecord(id: id, itemID: itemID, collectionID: collectionID, participantID: participant, participantName: "", value: 0)
            if existing == nil { modelContext.insert(value) }; value.participantName = record["participantName"] as? String ?? ""; value.value = record["value"] as? Int ?? 0; value.updatedAt = updated
        case "CollectionItemComment":
            guard let id = uuid, let itemID = UUID(uuidString: record["itemID"] as? String ?? ""), let participant = record["participantID"] as? String, let text = record["text"] as? String else { throw CollectionCodecError.malformedRecord }
            let existing = try first(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.id == id && $0.collectionID == collectionID }))
            let updated = record["updatedAt"] as? Date ?? .distantPast
            if let existing, existing.updatedAt > updated { return }
            let value = existing ?? ItemCommentRecord(id: id, itemID: itemID, collectionID: collectionID, participantID: participant, participantName: "", text: text, createdAt: record["createdAt"] as? Date ?? updated)
            if existing == nil { modelContext.insert(value) }; value.text = text; value.participantName = record["participantName"] as? String ?? ""; value.updatedAt = updated
        case CKRecord.SystemType.share: break
        default: throw CollectionCodecError.malformedRecord
        }
    }

    private func applyDeletion(_ id: CKRecord.ID, scope: CollaborationDatabaseScope) throws {
        let collectionID = try self.collectionID(for: id.zoneID, scope: scope)
        let state = try systemState(for: id, scope: scope)
        let uuid = UUID(uuidString: id.recordName)
        if state?.recordType == "Collection" || uuid == collectionID {
            if let zone = try zones().first(where: { $0.collectionID == collectionID }) { zone.roleRawValue = "viewer" }
            try applyAccess(collectionID: collectionID, role: .viewer)
            return // Preserve the graph on lost root/zone access; never delete owner data.
        }
        if let uuid, let item = try first(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.id == uuid && $0.collectionID == collectionID })) {
            let itemID = item.id
            for child in try modelContext.fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.itemID == itemID && $0.collectionID == collectionID })) { modelContext.delete(child) }
            for child in try modelContext.fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.itemID == itemID && $0.collectionID == collectionID })) { modelContext.delete(child) }
            for child in try modelContext.fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.itemID == itemID && $0.collectionID == collectionID })) { modelContext.delete(child) }
            modelContext.delete(item)
        }
        if let uuid {
            if let value = try first(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.id == uuid && $0.collectionID == collectionID })) { modelContext.delete(value) }
            if let value = try first(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.id == uuid && $0.collectionID == collectionID })) { modelContext.delete(value) }
        }
        if id.recordName.count >= 44, id.recordName.dropFirst(36).hasPrefix("-rating-"), let itemID = UUID(uuidString: String(id.recordName.prefix(36))) {
            let participant = String(id.recordName.dropFirst(44))
            if let value = try first(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.itemID == itemID && $0.participantID == participant && $0.collectionID == collectionID })) { modelContext.delete(value) }
        }
        if let state { modelContext.delete(state) }
    }

    func reconcileFailedSave(attemptedRecord: CKRecord, serverRecord: CKRecord?, error: CKError, in scope: CollaborationDatabaseScope) throws {
        beginOperation()
        defer { endOperation() }

        try recordUploadFailure(attemptedRecord.recordID, type: attemptedRecord.recordType, error: error, scope: scope)
        guard error.code == .serverRecordChanged, let serverRecord else { try commit(); return }
        let deleteCollection = try self.collectionID(for: attemptedRecord.recordID.zoneID, scope: scope)
        let deleteName = attemptedRecord.recordID.recordName
        let localDelete = try first(FetchDescriptor<SyncMutationRecord>(predicate: #Predicate { $0.collectionID == deleteCollection && $0.recordName == deleteName && $0.operation == "delete" })) != nil
        if try localDelete || (outgoing(scope).contains { rowID($0) == attemptedRecord.recordID && $0.operation == "delete" }) {
            // The old save has been superseded locally. Remember server fields
            // and retire only that old generation; never reinsert its payload.
            try acknowledgeSentChanges(savedRecords: [serverRecord], deletedRecordIDs: [], in: scope)
            return
        }
        let collectionID = try self.collectionID(for: attemptedRecord.recordID.zoneID, scope: scope)
        let currentModel = try domainModel(recordName: attemptedRecord.recordID.recordName, type: attemptedRecord.recordType, collectionID: collectionID)
        let current = try currentModel.map { try encodeModel($0, id: attemptedRecord.recordID, scope: scope) } ?? attemptedRecord
        let localTime = current["updatedAt"] as? Date ?? current["timestamp"] as? Date ?? .distantPast
        let serverTime = serverRecord["updatedAt"] as? Date ?? serverRecord["timestamp"] as? Date ?? .distantPast
        try remember(serverRecord, scope: scope)
        if serverTime >= localTime {
            try apply(serverRecord, scope: scope)
            try acknowledgeSentChanges(savedRecords: [serverRecord], deletedRecordIDs: [], in: scope)
        } else if try outgoing(scope).contains(where: { rowID($0) == attemptedRecord.recordID && $0.operation == "save" }) {
            // Retry the domain winner using current server system fields/change tag.
            let collectionID = try self.collectionID(for: attemptedRecord.recordID.zoneID, scope: scope)
            if let model = try domainModel(recordName: attemptedRecord.recordID.recordName, type: attemptedRecord.recordType, collectionID: collectionID) {
                let rebased = try encodeModel(model, id: attemptedRecord.recordID, scope: scope)
                let superseded = try outgoing(scope).filter { rowID($0) == attemptedRecord.recordID && $0.operation == "save" }
                let coveredIDs = try superseded.flatMap { try JSONDecoder().decode([UUID].self, from: $0.mutationIDs) }
                try stage(.save(rebased), mutationIDs: coveredIDs, scope: scope)
                for old in superseded { modelContext.delete(old) }
                inFlight.removeValue(forKey: identity(attemptedRecord.recordID, scope: scope))
            }
            try commit()
        }
    }

    private func failureRows(for id: CKRecord.ID, scope: CollaborationDatabaseScope) throws -> [CollectionOutgoingSnapshot] {
        let key = partition, raw = scope.rawValue, owner = id.zoneID.ownerName, zone = id.zoneID.zoneName, name = id.recordName
        return try modelContext.fetch(FetchDescriptor<CollectionOutgoingSnapshot>(predicate: #Predicate {
            $0.partition == key && $0.scope == raw && $0.ownerName == owner && $0.zoneName == zone && $0.recordName == name && $0.operation == "syncFailure"
        }))
    }

    /// Retain bounded, local-only per-record diagnostics instead of silently
    /// swallowing a server rejection. No record values, tokens or credentials.
    private func recordUploadFailure(_ id: CKRecord.ID, type: String, error: CKError, scope: CollaborationDatabaseScope) throws {
        let rows = try failureRows(for: id, scope: scope)
        let value = rows.first ?? CollectionOutgoingSnapshot(partition: partition, scope: scope.rawValue,
            zoneName: id.zoneID.zoneName, ownerName: id.zoneID.ownerName, recordName: id.recordName)
        if value.modelContext == nil { modelContext.insert(value) }
        value.collectionID = try collectionID(for: id.zoneID, scope: scope)
        value.recordType = type; value.operation = "syncFailure"
        value.recordArchive = try JSONEncoder().encode(["code": String(error.code.rawValue), "message": String(error.localizedDescription.prefix(500))])
        let covered = Set(try outgoing(scope).filter { rowID($0) == id }.flatMap { try JSONDecoder().decode([UUID].self, from: $0.mutationIDs) })
        for mutation in try modelContext.fetch(FetchDescriptor<SyncMutationRecord>()) where covered.contains(mutation.id) {
            mutation.attempts += 1
            mutation.lastError = "CloudKit upload failed (\(error.code.rawValue))."
        }
    }

    func retainFailedDelete(_ recordID: CKRecord.ID, error: CKError, in scope: CollaborationDatabaseScope) throws {
        beginOperation()
        defer { endOperation() }

        // No acknowledgement, no journal removal. A retry restores it on restart.
        try recordUploadFailure(recordID, type: "delete", error: error, scope: scope)
        try state(scope).lastFailure = "A cloud deletion is still pending."
        try commit()
    }

    func applyFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges, in scope: CollaborationDatabaseScope) throws {
        beginOperation()
        defer { endOperation() }

        for deleted in event.deletions {
            for zone in try zones() where zone.scope == scope.rawValue && zone.zoneName == deleted.zoneID.zoneName && zone.ownerName == deleted.zoneID.ownerName {
                zone.roleRawValue = "viewer"; zone.active = false; try applyAccess(collectionID: zone.collectionID, role: .viewer)
            }
        }
        try commit()
    }
    func applySentDatabaseChanges(_ event: CKSyncEngine.Event.SentDatabaseChanges, in scope: CollaborationDatabaseScope) throws {
        beginOperation()
        defer { endOperation() }

 try commit() }
    func accountDidChange(_ event: CKSyncEngine.Event.AccountChange, in scope: CollaborationDatabaseScope) throws {
        try handleAccountChange(event.changeType)
    }

    /// CKSyncEngine reports initial sign-in when starting without serialized
    /// state. That is expected, not an account switch. Never adopt a new account
    /// into an existing graph or clear its journal in response to this event.
    func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) throws {
        beginOperation()
        defer { endOperation() }
        switch change {
        case .signIn(let currentUser):
            eventFailureDiagnostic = "Account event: initial sign-in"
            let current = SHA256.hash(data: Data(currentUser.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
            guard current == accountPartitionIdentifier else {
                eventFailureDiagnostic = "Account event: sign-in partition mismatch"
                throw CollectionCodecError.accountPartitionMismatch
            }
            try claimGraph()
            try commit()
            eventFailureDiagnostic = nil
        case .signOut:
            eventFailureDiagnostic = "Account event: signed out"
            throw CollectionCodecError.accountPartitionMismatch
        case .switchAccounts:
            eventFailureDiagnostic = "Account event: switched accounts"
            throw CollectionCodecError.accountPartitionMismatch
        @unknown default:
            eventFailureDiagnostic = "Account event: unrecognized change"
            throw CollectionCodecError.accountPartitionMismatch
        }
    }

    func encode(_ change: SwiftDataHistoryChange, in scope: CollaborationDatabaseScope) throws -> [CloudKitRecordChange] {
        beginOperation()
        defer { endOperation() }

        // The explicit repository outbox is the host's durable incremental source.
        // Imported transactions have no outbox rows and therefore cannot echo.
        return try stageRepositoryMutations()[scope] ?? []
    }
    func isHistoryCursorExpired(_ error: any Error) -> Bool { false }
    func recoverExpiredHistoryCursor(after cursorData: Data?, in scope: CollaborationDatabaseScope) throws -> SwiftDataHistoryBatch {
        throw CollectionCodecError.handoffIncomplete // Never reset history or scan unboundedly.
    }
}
