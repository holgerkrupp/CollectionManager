import CloudKit
import UIKit

enum SharingError: LocalizedError {
    case unavailable
    case noAccount
    case restricted
    case temporarilyUnavailable
    case invalidInvitation
    case invitationNotReady

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "iCloud sharing is unavailable on this device."
        case .noAccount:
            "No iCloud account is available to Collection Manager. Sign in to iCloud, enable iCloud Drive, and try again."
        case .restricted:
            "This iCloud account is restricted from sharing. Check Screen Time or device-management restrictions and try again."
        case .temporarilyUnavailable:
            "iCloud is temporarily unavailable. Check your connection and try again."
        case .invalidInvitation:
            "This invitation does not belong to Collection Manager. Ask the owner to send a new invitation from the app."
        case .invitationNotReady:
            "The invitation was accepted, but iCloud is still preparing the shared collection. Wait a moment and try syncing again."
        }
    }
}

struct CloudCollectionSnapshot: Sendable {
    let collection: CollectionModel
    let items: [CollectionItem]
    let deletedItemIDs: [UUID]
    let events: [ItemEvent]
    let ratings: [ItemRating]
    let comments: [ItemComment]
    let sharedWith: [CloudCollectionParticipant]?
}

struct CloudCollectionParticipant: Sendable {
    let id: String
    let displayName: String
}

struct CloudSyncMutation: Sendable {
    let id: UUID
    let collectionID: UUID
    let itemID: UUID?
    let recordName: String
    let recordType: String
    let operation: String
}

final class CloudKitSharingService {
    static let containerIdentifier = "iCloud.de.holgerkrupp.CollectionManager"
    private static let bootstrapKey = "cloudSync.didBootstrapLocalData"
    private static let imageBootstrapKey = "cloudSync.didUploadImagesV1"
    private var injectedContainer: CKContainer?
    private lazy var container: CKContainer = injectedContainer ?? CKContainer(identifier: Self.containerIdentifier)

    init(container: CKContainer? = nil) { injectedContainer = container }

    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        // The CLI simulator build is intentionally unsigned, so CloudKit would
        // abort inside CKContainer instead of returning an ordinary error.
        return false
        #else
        return true
        #endif
    }

    func makeShare(for collection: CollectionModel, items: [CollectionItem], events: [ItemEvent] = []) async throws -> CKShare {
        guard Self.isAvailable else { throw SharingError.unavailable }
        try await requireAvailableAccount()
        let database = container.privateCloudDatabase
        let zoneID = zoneID(for: collection.id)
        let existingZones = try await database.allRecordZones()
        if !existingZones.contains(where: { $0.zoneID == zoneID }) {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        }
        let rootID = CKRecord.ID(recordName: collection.id.uuidString, zoneID: zoneID)
        let collectionItems = await preparedItemsForCloud(items.filter { $0.collectionID == collection.id })
        let itemRecords = collectionItems.map { record(for: $0, zoneID: zoneID, parent: rootID) }
        let eventRecords = events.map { record(for: $0, zoneID: zoneID, parent: rootID) }
        let ratingRecords = collectionItems.flatMap { $0.ratings.map { record(for: $0, zoneID: zoneID, parent: CKRecord.ID(recordName: $0.itemID.uuidString, zoneID: zoneID)) } }
        let commentRecords = collectionItems.flatMap { $0.comments.map { record(for: $0, zoneID: zoneID, parent: CKRecord.ID(recordName: $0.itemID.uuidString, zoneID: zoneID)) } }
        let share = try await createOrUpdateShare(for: collection, rootID: rootID, database: database)
        let descendants = itemRecords + eventRecords + ratingRecords + commentRecords
        for batch in descendants.chunked(maxCount: 300) {
            try await saveRecordsResiliently(batch, in: database)
        }
        return share
    }

    private func createOrUpdateShare(for collection: CollectionModel, rootID: CKRecord.ID, database: CKDatabase) async throws -> CKShare {
        var lastError: Error = SharingError.unavailable
        for attempt in 0..<3 {
            let root: CKRecord
            do {
                root = try await database.record(for: rootID)
            } catch let error as CKError where error.code == .unknownItem {
                root = CKRecord(recordType: "Collection", recordID: rootID)
            }
            root["name"] = collection.name as CKRecordValue
            root["icon"] = collection.icon as CKRecordValue
            root["subtitle"] = collection.subtitle as CKRecordValue
            root["settingsJSON"] = settingsJSON(for: collection) as CKRecordValue
            root["updatedAt"] = Date.now as CKRecordValue

            let existingShare: CKShare? = if let shareID = root.share?.recordID {
                try await database.record(for: shareID) as? CKShare
            } else {
                nil
            }
            let share = existingShare ?? CKShare(rootRecord: root)
            share[CKShare.SystemFieldKey.title] = collection.name as CKRecordValue
            share.publicPermission = .none

            do {
                try await saveSharePair(root: root, share: share, in: database)
                return share
            } catch {
                lastError = error
                guard attempt < 2, isRetryableShareConflict(error) else { throw error }
                await Task.yield()
            }
        }
        throw lastError
    }

    private func saveSharePair(root: CKRecord, share: CKShare, in database: CKDatabase) async throws {
        let collector = CloudKitOperationErrorCollector()
        let operation = CKModifyRecordsOperation(recordsToSave: [root, share], recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.isAtomic = true
        operation.perRecordSaveBlock = { _, result in
            if case .failure(let error) = result { collector.append(error) }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            operation.modifyRecordsResultBlock = { result in
                if case .failure(let error) = result { collector.append(error) }
                continuation.resume()
            }
            database.add(operation)
        }
        let errors = collector.snapshot().map(underlyingCloudKitCause(in:))
        if let cause = errors.first(where: { !isBatchFailure($0) }) ?? errors.first { throw cause }
    }

    private func isRetryableShareConflict(_ error: Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        return cloudError.code == .serverRecordChanged || cloudError.code == .constraintViolation || isBatchFailure(error)
    }

    func controller(for share: CKShare) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        return controller
    }

    func sync(collections: [CollectionModel], items: [CollectionItem], events: [ItemEvent], mutations: [CloudSyncMutation]) async throws -> [CloudCollectionSnapshot] {
        guard Self.isAvailable else { throw SharingError.unavailable }
        let needsImageBootstrap = !UserDefaults.standard.bool(forKey: Self.imageBootstrapKey)
        var cloudItems = await preparedItemsForCloud(items)
        if needsImageBootstrap {
            let migrationDate = Date.now
            for index in cloudItems.indices where cloudItems[index].imageData != nil {
                cloudItems[index].updatedAt = migrationDate
            }
        }
        try await push(collections: collections, items: cloudItems, events: events, mutations: mutations)
        async let privateSnapshots = fetchSnapshots(from: container.privateCloudDatabase)
        async let sharedSnapshots = fetchSnapshots(from: container.sharedCloudDatabase)
        let snapshots = try await privateSnapshots + sharedSnapshots
        UserDefaults.standard.set(true, forKey: Self.bootstrapKey)
        UserDefaults.standard.set(true, forKey: Self.imageBootstrapKey)
        return snapshots
    }

    func acceptShare(from url: URL) async throws {
        guard Self.isAvailable else { throw SharingError.unavailable }
        let metadata: CKShare.Metadata = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKShare.Metadata, Error>) in
            container.fetchShareMetadata(with: url) { metadata, error in
                if let metadata { continuation.resume(returning: metadata) } else { continuation.resume(throwing: error ?? SharingError.unavailable) }
            }
        }
        try await acceptShare(metadata: metadata)
    }

    func acceptShare(metadata: CKShare.Metadata) async throws {
        guard Self.isAvailable else { throw SharingError.unavailable }
        guard metadata.containerIdentifier == Self.containerIdentifier else { throw SharingError.invalidInvitation }
        try await requireAvailableAccount()

        if metadata.participantStatus == .pending {
            let invitationContainer = CKContainer(identifier: metadata.containerIdentifier)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
                operation.acceptSharesResultBlock = { result in
                    switch result {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                invitationContainer.add(operation)
            }
        }

        guard let rootRecordID = metadata.hierarchicalRootRecordID else { throw SharingError.invalidInvitation }
        try await waitForSharedRoot(rootRecordID)
    }

    private func waitForSharedRoot(_ rootRecordID: CKRecord.ID) async throws {
        // A successful CKAcceptSharesOperation can finish before CloudKit has
        // exposed the shared zone. Do not sync until the hierarchy root is
        // readable, otherwise a valid invitation appears to contain no list.
        let retryDelays: [UInt64] = [0, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000]
        for delay in retryDelays {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            do {
                _ = try await container.sharedCloudDatabase.record(for: rootRecordID)
                return
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound || error.code == .serviceUnavailable { }
        }

        throw SharingError.invitationNotReady
    }

    private func push(collections: [CollectionModel], items: [CollectionItem], events: [ItemEvent], mutations: [CloudSyncMutation]) async throws {
        // Local mutations are the outbox. Re-uploading every item and event on
        // every launch is slow and creates avoidable CloudKit conflicts. Keep a
        // one-time bootstrap for data created by older app versions that had no
        // outbox records yet.
        let needsBootstrap = !UserDefaults.standard.bool(forKey: Self.bootstrapKey)
        let needsImageBootstrap = !UserDefaults.standard.bool(forKey: Self.imageBootstrapKey)
        guard needsBootstrap || needsImageBootstrap || !mutations.isEmpty else { return }
        let sharedZones = (try? await container.sharedCloudDatabase.allRecordZones()) ?? []
        let sharedZonesByName = Dictionary(uniqueKeysWithValues: sharedZones.map { ($0.zoneID.zoneName, $0.zoneID) })
        let localCollectionIDs = Set(collections.map(\.id))
        let deletedCollectionIDs = Set(mutations.filter { $0.operation == "delete" && $0.recordType == "Collection" && !localCollectionIDs.contains($0.collectionID) }.map(\.collectionID))
        for collectionID in deletedCollectionIDs {
            let zone = zoneID(for: collectionID)
            do {
                _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zone)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                // Already gone is the desired state.
            }
        }
        for collection in collections {
            let collectionMutations = mutations.filter { $0.collectionID == collection.id && $0.recordType == "Collection" }
            let itemMutations = mutations.filter { $0.collectionID == collection.id && $0.recordType == "CollectionItem" && $0.operation != "delete" }
            let ratingMutations = mutations.filter { $0.collectionID == collection.id && $0.recordType == "CollectionItemRating" }
            let commentMutations = mutations.filter { $0.collectionID == collection.id && $0.recordType == "CollectionItemComment" }
            let deleteMutations = mutations.filter { $0.collectionID == collection.id && $0.operation == "delete" }
            let hasImagesToBootstrap = needsImageBootstrap && items.contains { $0.collectionID == collection.id && $0.imageData != nil }
            let isOwner = collection.role == .owner
            let database: CKDatabase
            let zone: CKRecordZone.ID
            if isOwner {
                database = container.privateCloudDatabase
                zone = zoneID(for: collection.id)
            } else {
                guard let sharedZone = sharedZonesByName["collection-\(collection.id.uuidString)"] else { continue }
                database = container.sharedCloudDatabase
                zone = sharedZone
            }
            let shouldSaveCollection = isOwner && (needsBootstrap || collectionMutations.contains { $0.operation != "delete" })
            let shouldBootstrap = isOwner && needsBootstrap
            guard shouldSaveCollection || hasImagesToBootstrap || !itemMutations.isEmpty || !ratingMutations.isEmpty || !commentMutations.isEmpty || !deleteMutations.isEmpty else { continue }
            if isOwner { do { _ = try await database.save(CKRecordZone(zoneID: zone)) } catch let error as CKError where error.code == .serverRejectedRequest { } }
            let rootID = CKRecord.ID(recordName: collection.id.uuidString, zoneID: zone)
            var saving: [CKRecord] = []

            if shouldSaveCollection {
                let root = (try? await database.record(for: rootID)) ?? CKRecord(recordType: "Collection", recordID: rootID)
                root["name"] = collection.name as CKRecordValue; root["icon"] = collection.icon as CKRecordValue; root["subtitle"] = collection.subtitle as CKRecordValue; root["settingsJSON"] = settingsJSON(for: collection) as CKRecordValue; root["updatedAt"] = Date.now as CKRecordValue
                // Commit the shared root independently. If a root update fails,
                // including it with hundreds of descendants turns every child
                // error into CKError.batchRequestFailed and obscures the cause.
                // Saving it first also guarantees that new child parents exist.
                try await modifyRecords(in: database, saving: [root], atomically: false)
            }

            let itemIDs = Set(itemMutations.compactMap { $0.itemID ?? UUID(uuidString: $0.recordName) })
            // A collection mutation only changes the root metadata. Re-uploading
            // every child makes an unrelated stale item poison the entire
            // custom-zone batch. After the one-time bootstrap, honor the outbox
            // and save only item records that actually changed.
            let collectionItems = shouldBootstrap
                ? items.filter { $0.collectionID == collection.id }
                : items.filter { itemIDs.contains($0.id) || (hasImagesToBootstrap && $0.collectionID == collection.id && $0.imageData != nil) }
            saving.append(contentsOf: collectionItems.map { record(for: $0, zoneID: zone, parent: rootID) })
            let eventItemIDs = Set(collectionItems.map(\.id))
            saving.append(contentsOf: events.filter { eventItemIDs.contains($0.itemID) }.map { record(for: $0, zoneID: zone, parent: rootID) })

            let collectionRatings = items.filter { $0.collectionID == collection.id }.flatMap(\.ratings)
            let collectionComments = items.filter { $0.collectionID == collection.id }.flatMap(\.comments)
            let ratingNames = Set(ratingMutations.filter { $0.operation != "delete" }.map(\.recordName))
            let commentNames = Set(commentMutations.filter { $0.operation != "delete" }.map(\.recordName))
            let ratingsToSave = shouldBootstrap ? collectionRatings : collectionRatings.filter { ratingNames.contains(CollaborationRecordNames.rating(itemID: $0.itemID, participantID: $0.participantID)) }
            let commentsToSave = shouldBootstrap ? collectionComments : collectionComments.filter { commentNames.contains(CollaborationRecordNames.comment($0.id)) }
            saving.append(contentsOf: ratingsToSave.map { record(for: $0, zoneID: zone, parent: CKRecord.ID(recordName: $0.itemID.uuidString, zoneID: zone)) })
            saving.append(contentsOf: commentsToSave.map { record(for: $0, zoneID: zone, parent: CKRecord.ID(recordName: $0.itemID.uuidString, zoneID: zone)) })
            // CloudKit has per-operation record limits. Chunking also avoids one
            // large bootstrap monopolizing the sync task.
            for batch in saving.chunked(maxCount: 300) {
                try await saveRecordsResiliently(batch, in: database)
            }
            let deleting = deleteMutations.map { CKRecord.ID(recordName: $0.recordName, zoneID: zone) }
            for batch in deleting.chunked(maxCount: 300) {
                try await deleteRecordsResiliently(batch, in: database)
            }
        }
    }

    private func saveRecordsResiliently(_ records: [CKRecord], in database: CKDatabase) async throws {
        defer { removeTemporaryAssets(from: records) }
        do {
            try await modifyRecords(in: database, saving: records, atomically: false)
        } catch {
            guard isBatchFailure(error), records.count > 1 else { throw error }
            let midpoint = records.count / 2
            try await saveRecordsResiliently(Array(records[..<midpoint]), in: database)
            try await saveRecordsResiliently(Array(records[midpoint...]), in: database)
        }
    }

    private func deleteRecordsResiliently(_ recordIDs: [CKRecord.ID], in database: CKDatabase) async throws {
        do {
            try await modifyRecords(in: database, deleting: recordIDs, atomically: false)
        } catch let error as CKError where error.code == .unknownItem {
            // Deleting a record that is already absent is successful convergence.
        } catch {
            guard isBatchFailure(error), recordIDs.count > 1 else { throw error }
            let midpoint = recordIDs.count / 2
            try await deleteRecordsResiliently(Array(recordIDs[..<midpoint]), in: database)
            try await deleteRecordsResiliently(Array(recordIDs[midpoint...]), in: database)
        }
    }

    private func requireAvailableAccount() async throws {
        switch try await container.accountStatus() {
        case .available:
            return
        case .noAccount:
            throw SharingError.noAccount
        case .restricted:
            throw SharingError.restricted
        case .temporarilyUnavailable, .couldNotDetermine:
            throw SharingError.temporarilyUnavailable
        @unknown default:
            throw SharingError.unavailable
        }
    }

    private func modifyRecords(
        in database: CKDatabase,
        saving: [CKRecord] = [],
        deleting: [CKRecord.ID] = [],
        atomically: Bool
    ) async throws {
        guard !saving.isEmpty || !deleting.isEmpty else { return }
        let result: (saveResults: [CKRecord.ID: Result<CKRecord, Error>], deleteResults: [CKRecord.ID: Result<Void, Error>])
        do {
            result = try await database.modifyRecords(
                saving: saving,
                deleting: deleting,
                savePolicy: .changedKeys,
                atomically: atomically
            )
        } catch {
            throw underlyingCloudKitCause(in: error)
        }
        let errors = result.saveResults.values.compactMap { result -> Error? in
            guard case .failure(let error) = result else { return nil }
            return error
        } + result.deleteResults.values.compactMap { result -> Error? in
            guard case .failure(let error) = result else { return nil }
            return error
        }
        if let cause = errors.first(where: { !isBatchFailure($0) }) ?? errors.first {
            throw underlyingCloudKitCause(in: cause)
        }
    }

    private func underlyingCloudKitCause(in error: Error) -> Error {
        guard let cloudError = error as? CKError,
              let partialErrors = cloudError.partialErrorsByItemID,
              !partialErrors.isEmpty else { return error }
        let causes = partialErrors.values.map(underlyingCloudKitCause(in:))
        return causes.first(where: { ($0 as? CKError)?.code != .batchRequestFailed }) ?? causes[0]
    }

    private func isBatchFailure(_ error: Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        return cloudError.code == .batchRequestFailed || cloudError.code == .partialFailure
    }

    private func fetchSnapshots(from database: CKDatabase) async throws -> [CloudCollectionSnapshot] {
        let zones = try await database.allRecordZones()
        var snapshots: [CloudCollectionSnapshot] = []
        for zone in zones where zone.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
            let zoneRecords: [CKRecord]
            let deletedItemIDs: [UUID]
            do {
                (zoneRecords, deletedItemIDs) = try await records(in: zone.zoneID, database: database)
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
                // A newly-created or previously-cleared custom zone has no
                // Collection type/record yet. It is empty, not a sync failure.
                continue
            }
            for root in zoneRecords where root.recordType == "Collection" {
                guard let id = UUID(uuidString: root.recordID.recordName) else { continue }
                let items = zoneRecords.filter { $0.recordType == "CollectionItem" }.compactMap { item(from: $0, collectionID: id) }
                let events = zoneRecords.filter { $0.recordType == "CollectionEvent" }.compactMap(event(from:))
                let ratings = zoneRecords.filter { $0.recordType == "CollectionItemRating" }.compactMap(rating(from:))
                let comments = zoneRecords.filter { $0.recordType == "CollectionItemComment" }.compactMap(comment(from:))
                let settings = decodeSettings(root["settingsJSON"] as? String)
                let sharedWith = await sharedParticipants(for: root, in: database)
                snapshots.append(CloudCollectionSnapshot(collection: CollectionModel(id: id, name: root["name"] as? String ?? "Collection", icon: root["icon"] as? String ?? "square.stack", subtitle: root["subtitle"] as? String ?? "Shared", category: settings.category, statuses: settings.statuses, mergedTags: settings.mergedTags, metadataFields: settings.metadataFields, role: database.databaseScope == .shared ? .editor : .owner), items: items, deletedItemIDs: deletedItemIDs, events: events, ratings: ratings, comments: comments, sharedWith: sharedWith))
            }
        }
        return snapshots
    }

    private func sharedParticipants(for root: CKRecord, in database: CKDatabase) async -> [CloudCollectionParticipant]? {
        guard let shareID = root.share?.recordID else { return [] }
        guard let share = try? await database.record(for: shareID) as? CKShare else { return nil }
        let currentUserID = share.currentUserParticipant?.userIdentity.userRecordID?.recordName
        let formatter = PersonNameComponentsFormatter()
        return share.participants.compactMap { participant in
            let identity = participant.userIdentity
            let participantID = identity.userRecordID?.recordName
            if let currentUser = share.currentUserParticipant, participant === currentUser { return nil }
            if let participantID, let currentUserID, participantID == currentUserID { return nil }
            guard participant.acceptanceStatus != .removed, let components = identity.nameComponents else { return nil }
            let name = formatter.string(from: components).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return CloudCollectionParticipant(id: participantID ?? name, displayName: name)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func records(in zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> ([CKRecord], [UUID]) {
        // Zone changes enumerate custom-zone records without CKQuery indexes.
        // Passing nil starts from the beginning, which is appropriate here
        // because the local merge currently expects a complete snapshot.
        var changeToken: CKServerChangeToken?
        var records: [CKRecord] = []
        var deletedItemIDs: [UUID] = []
        var moreComing = true
        while moreComing {
            let page = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: changeToken,
                desiredKeys: nil,
                resultsLimit: 400
            )
            records.append(contentsOf: page.modificationResultsByID.values.compactMap { result in
                try? result.get().record
            })
            deletedItemIDs.append(contentsOf: page.deletions
                .filter { $0.recordType == "CollectionItem" }
                .compactMap { UUID(uuidString: $0.recordID.recordName) })
            changeToken = page.changeToken
            moreComing = page.moreComing
        }

        // A participant's first shared-zone change request can succeed before
        // CloudKit includes the hierarchy's existing records in that feed. In
        // that case there is no Collection root to merge and the accepted list
        // remains invisible. Query the current hierarchy as a fallback; later
        // syncs normally continue to use the cheaper zone-change result.
        if !records.contains(where: { $0.recordType == "Collection" }) {
            let currentRecords = try await queryCurrentRecords(in: zoneID, database: database)
            var recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) })
            for record in currentRecords { recordsByID[record.recordID] = record }
            records = Array(recordsByID.values)
        }
        return (records, deletedItemIDs)
    }

    private func queryCurrentRecords(in zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> [CKRecord] {
        let requiredTypes = ["Collection", "CollectionItem", "CollectionEvent"]
        let optionalTypes = ["CollectionItemRating", "CollectionItemComment"]
        var records: [CKRecord] = []

        for recordType in requiredTypes + optionalTypes {
            do {
                records.append(contentsOf: try await queryRecords(ofType: recordType, in: zoneID, database: database))
            } catch let error as CKError where optionalTypes.contains(recordType) && (error.code == .unknownItem || error.code == .invalidArguments || error.code == .serverRejectedRequest) {
                // Older deployed schemas may not contain optional collaboration
                // types yet. Their absence must not hide the collection itself.
            }
        }
        return records
    }

    private func queryRecords(ofType recordType: String, in zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var records: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let cursor {
                page = try await database.records(continuingMatchFrom: cursor, desiredKeys: nil, resultsLimit: 400)
            } else {
                page = try await database.records(matching: query, inZoneWith: zoneID, desiredKeys: nil, resultsLimit: 400)
            }
            records.append(contentsOf: page.matchResults.compactMap { try? $0.1.get() })
            cursor = page.queryCursor
        } while cursor != nil

        return records
    }

    private func settingsJSON(for collection: CollectionModel) -> String { let payload = CollectionSettingsPayload(category: collection.category, statuses: collection.statuses, mergedTags: collection.mergedTags, metadataFields: collection.metadataFields); return (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "{}" }
    private func decodeSettings(_ string: String?) -> CollectionSettingsPayload { guard let string, let data = string.data(using: .utf8), let payload = try? JSONDecoder().decode(CollectionSettingsPayload.self, from: data) else { return CollectionSettingsPayload() }; return payload }
    private func zoneID(for collectionID: UUID) -> CKRecordZone.ID { CKRecordZone.ID(zoneName: "collection-\(collectionID.uuidString)", ownerName: CKCurrentUserDefaultName) }
    private func record(for item: CollectionItem, zoneID: CKRecordZone.ID, parent: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "CollectionItem", recordID: CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID))
        record["collectionID"] = item.collectionID.uuidString as CKRecordValue; record["title"] = item.title as CKRecordValue; record["brand"] = item.brand as CKRecordValue; record["variant"] = item.variant as CKRecordValue; record["itemDescription"] = item.itemDescription as CKRecordValue; record["state"] = item.state.rawValue as CKRecordValue; record["quantity"] = item.quantity as CKRecordValue; record["createdAt"] = item.createdAt as CKRecordValue; record["updatedAt"] = item.updatedAt as CKRecordValue; if let consumedAt = item.consumedAt { record["consumedAt"] = consumedAt as CKRecordValue }; if let tags = try? String(data: JSONEncoder().encode(item.tags), encoding: .utf8) { record["tagsJSON"] = tags as CKRecordValue }; if let metadata = try? String(data: JSONEncoder().encode(item.metadata), encoding: .utf8) { record["metadataJSON"] = metadata as CKRecordValue }; if let snapshot = item.sourceSnapshot, let snapshotJSON = try? String(data: JSONEncoder().encode(snapshot), encoding: .utf8) { record["sourceSnapshotJSON"] = snapshotJSON as CKRecordValue }; if let barcode = item.barcode { record["barcodeValue"] = barcode.value as CKRecordValue; record["barcodeType"] = barcode.type as CKRecordValue }; if let imageData = item.imageData, let asset = temporaryAsset(for: imageData, itemID: item.id) { record["imageAsset"] = asset }; record.parent = CKRecord.Reference(recordID: parent, action: .none); return record
    }
    private func record(for event: ItemEvent, zoneID: CKRecordZone.ID, parent: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "CollectionEvent", recordID: CKRecord.ID(recordName: event.id.uuidString, zoneID: zoneID))
        record["itemID"] = event.itemID.uuidString as CKRecordValue
        record["timestamp"] = event.timestamp as CKRecordValue
        record["type"] = event.type as CKRecordValue
        if let note = event.note { record["note"] = note as CKRecordValue }
        record.parent = CKRecord.Reference(recordID: parent, action: .none)
        return record
    }
    private func record(for rating: ItemRating, zoneID: CKRecordZone.ID, parent: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "CollectionItemRating", recordID: CKRecord.ID(recordName: CollaborationRecordNames.rating(itemID: rating.itemID, participantID: rating.participantID), zoneID: zoneID))
        record["id"] = rating.id.uuidString as CKRecordValue
        record["itemID"] = rating.itemID.uuidString as CKRecordValue
        record["participantID"] = rating.participantID as CKRecordValue
        record["participantName"] = rating.participantName as CKRecordValue
        record["value"] = rating.value as CKRecordValue
        record["updatedAt"] = rating.updatedAt as CKRecordValue
        record.parent = CKRecord.Reference(recordID: parent, action: .none)
        return record
    }
    private func record(for comment: ItemComment, zoneID: CKRecordZone.ID, parent: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "CollectionItemComment", recordID: CKRecord.ID(recordName: CollaborationRecordNames.comment(comment.id), zoneID: zoneID))
        record["id"] = comment.id.uuidString as CKRecordValue
        record["itemID"] = comment.itemID.uuidString as CKRecordValue
        record["participantID"] = comment.participantID as CKRecordValue
        record["participantName"] = comment.participantName as CKRecordValue
        record["text"] = comment.text as CKRecordValue
        record["createdAt"] = comment.createdAt as CKRecordValue
        record["updatedAt"] = comment.updatedAt as CKRecordValue
        record.parent = CKRecord.Reference(recordID: parent, action: .none)
        return record
    }
    private func event(from record: CKRecord) -> ItemEvent? {
        guard let id = UUID(uuidString: record.recordID.recordName), let itemID = UUID(uuidString: record["itemID"] as? String ?? "") else { return nil }
        return ItemEvent(id: id, itemID: itemID, timestamp: record["timestamp"] as? Date ?? .now, type: record["type"] as? String ?? "unknown", note: record["note"] as? String)
    }
    private func rating(from record: CKRecord) -> ItemRating? {
        guard let itemID = UUID(uuidString: record["itemID"] as? String ?? ""), let participantID = record["participantID"] as? String else { return nil }
        let id = UUID(uuidString: record["id"] as? String ?? "") ?? UUID()
        return ItemRating(id: id, itemID: itemID, participantID: participantID, participantName: record["participantName"] as? String ?? "Collaborator", value: record["value"] as? Int ?? 0, updatedAt: record["updatedAt"] as? Date ?? .now)
    }
    private func comment(from record: CKRecord) -> ItemComment? {
        guard let id = UUID(uuidString: record["id"] as? String ?? record.recordID.recordName), let itemID = UUID(uuidString: record["itemID"] as? String ?? ""), let participantID = record["participantID"] as? String, let text = record["text"] as? String else { return nil }
        return ItemComment(id: id, itemID: itemID, participantID: participantID, participantName: record["participantName"] as? String ?? "Collaborator", text: text, createdAt: record["createdAt"] as? Date ?? .now, updatedAt: record["updatedAt"] as? Date ?? .now)
    }
    private func item(from record: CKRecord, collectionID: UUID) -> CollectionItem? { guard let id = UUID(uuidString: record.recordID.recordName), let title = record["title"] as? String else { return nil }; let imageData = (record["imageAsset"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }; let sourceSnapshot: ProductSourceSnapshot? = decode(record["sourceSnapshotJSON"] as? String, fallback: nil); return CollectionItem(id: id, collectionID: collectionID, title: title, brand: record["brand"] as? String ?? "", variant: record["variant"] as? String ?? "", itemDescription: record["itemDescription"] as? String ?? "", state: ItemState(rawValue: record["state"] as? String ?? "wanted"), quantity: record["quantity"] as? Int ?? 1, barcode: (record["barcodeValue"] as? String).flatMap { Barcode(rawValue: $0, type: record["barcodeType"] as? String ?? "EAN-13") }, createdAt: record["createdAt"] as? Date ?? .now, updatedAt: record["updatedAt"] as? Date ?? .now, consumedAt: record["consumedAt"] as? Date, tags: decode(record["tagsJSON"] as? String, fallback: []), metadata: decode(record["metadataJSON"] as? String, fallback: [:]), imageSystemName: record["imageSystemName"] as? String ?? "shippingbox.fill", imageData: imageData, importSourceKey: record["importSourceKey"] as? String, sourceSnapshot: sourceSnapshot) }
    private func preparedItemsForCloud(_ items: [CollectionItem]) async -> [CollectionItem] {
        var prepared = items
        await withTaskGroup(of: (Int, Data).self) { group in
            for (index, item) in items.enumerated() {
                guard let imageData = item.imageData else { continue }
                group.addTask { (index, await ImageProcessor.preparedData(imageData)) }
            }
            for await (index, imageData) in group { prepared[index].imageData = imageData }
        }
        return prepared
    }
    private func temporaryAsset(for data: Data, itemID: UUID) -> CKAsset? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CollectionManager-\(itemID.uuidString)-\(UUID().uuidString).jpg")
        do { try data.write(to: url, options: .atomic); return CKAsset(fileURL: url) } catch { return nil }
    }
    private func removeTemporaryAssets(from records: [CKRecord]) {
        for record in records {
            guard let url = (record["imageAsset"] as? CKAsset)?.fileURL else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
    private func decode<T: Decodable>(_ string: String?, fallback: T) -> T { guard let string, let data = string.data(using: .utf8), let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }; return value }
}

private final class CloudKitOperationErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    func append(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    func snapshot() -> [Error] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }
}

private extension Array {
    func chunked(maxCount: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: maxCount).map { start in
            Array(self[start..<Swift.min(start + maxCount, count)])
        }
    }
}
