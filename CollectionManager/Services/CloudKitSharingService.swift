import CloudKit
import UIKit

enum SharingError: LocalizedError {
    case unavailable
    var errorDescription: String? { "iCloud sharing is unavailable. Sign in to iCloud and try again." }
}

struct CloudCollectionSnapshot: Sendable {
    let collection: CollectionModel
    let items: [CollectionItem]
    let events: [ItemEvent]
    let ratings: [ItemRating]
    let comments: [ItemComment]
}

final class CloudKitSharingService {
    static let containerIdentifier = "iCloud.de.holgerkrupp.CollectionManager"
    private static let bootstrapKey = "cloudSync.didBootstrapLocalData"
    private let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: CloudKitSharingService.containerIdentifier)) { self.container = container }

    func makeShare(for collection: CollectionModel, items: [CollectionItem], events: [ItemEvent] = []) async throws -> CKShare {
        let database = container.privateCloudDatabase
        let zoneID = zoneID(for: collection.id)
        do { _ = try await database.save(CKRecordZone(zoneID: zoneID)) } catch let error as CKError where error.code == .serverRejectedRequest { }
        let rootID = CKRecord.ID(recordName: collection.id.uuidString, zoneID: zoneID)
        let root = (try? await database.record(for: rootID)) ?? CKRecord(recordType: "Collection", recordID: rootID)
        root["name"] = collection.name as CKRecordValue; root["icon"] = collection.icon as CKRecordValue; root["subtitle"] = collection.subtitle as CKRecordValue; root["settingsJSON"] = settingsJSON(for: collection) as CKRecordValue; root["updatedAt"] = Date.now as CKRecordValue
        let itemRecords = items.map { record(for: $0, zoneID: zoneID, parent: rootID) }
        let eventRecords = events.map { record(for: $0, zoneID: zoneID, parent: rootID) }
        let ratingRecords = items.flatMap { $0.ratings.map { record(for: $0, zoneID: zoneID, parent: CKRecord.ID(recordName: $0.itemID.uuidString, zoneID: zoneID)) } }
        let commentRecords = items.flatMap { $0.comments.map { record(for: $0, zoneID: zoneID, parent: CKRecord.ID(recordName: $0.itemID.uuidString, zoneID: zoneID)) } }
        let share = CKShare(rootRecord: root)
        share[CKShare.SystemFieldKey.title] = collection.name as CKRecordValue
        share.publicPermission = .none
        _ = try await database.modifyRecords(saving: [root, share] + itemRecords + eventRecords + ratingRecords + commentRecords, deleting: [])
        return share
    }

    func controller(for share: CKShare) -> UICloudSharingController { UICloudSharingController(share: share, container: container) }

    func sync(collections: [CollectionModel], items: [CollectionItem], events: [ItemEvent], mutations: [SyncMutationRecord]) async throws -> [CloudCollectionSnapshot] {
        try await push(collections: collections, items: items, events: events, mutations: mutations)
        let privateSnapshots = try await fetchSnapshots(from: container.privateCloudDatabase)
        let sharedSnapshots = try await fetchSnapshots(from: container.sharedCloudDatabase)
        UserDefaults.standard.set(true, forKey: Self.bootstrapKey)
        return privateSnapshots + sharedSnapshots
    }

    func acceptShare(from url: URL) async throws {
        let metadata: CKShare.Metadata = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKShare.Metadata, Error>) in
            container.fetchShareMetadata(with: url) { metadata, error in
                if let metadata { continuation.resume(returning: metadata) } else { continuation.resume(throwing: error ?? SharingError.unavailable) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            container.add(operation)
        }
    }

    private func push(collections: [CollectionModel], items: [CollectionItem], events: [ItemEvent], mutations: [SyncMutationRecord]) async throws {
        // Local mutations are the outbox. Re-uploading every item and event on
        // every launch is slow and creates avoidable CloudKit conflicts. Keep a
        // one-time bootstrap for data created by older app versions that had no
        // outbox records yet.
        let needsBootstrap = !UserDefaults.standard.bool(forKey: Self.bootstrapKey)
        guard needsBootstrap || !mutations.isEmpty else { return }
        let sharedZones = (try? await container.sharedCloudDatabase.allRecordZones()) ?? []
        let sharedZonesByName = Dictionary(uniqueKeysWithValues: sharedZones.map { ($0.zoneID.zoneName, $0.zoneID) })
        for collection in collections {
            let collectionMutations = mutations.filter { $0.collectionID == collection.id && $0.recordType == "Collection" }
            let itemMutations = mutations.filter { $0.collectionID == collection.id && $0.recordType == "CollectionItem" && $0.operation != "delete" }
            let ratingMutations = mutations.filter { $0.collectionID == collection.id && $0.recordType == "CollectionItemRating" }
            let commentMutations = mutations.filter { $0.collectionID == collection.id && $0.recordType == "CollectionItemComment" }
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
            guard shouldSaveCollection || !itemMutations.isEmpty || !ratingMutations.isEmpty || !commentMutations.isEmpty else { continue }
            if isOwner { do { _ = try await database.save(CKRecordZone(zoneID: zone)) } catch let error as CKError where error.code == .serverRejectedRequest { } }
            let rootID = CKRecord.ID(recordName: collection.id.uuidString, zoneID: zone)
            var saving: [CKRecord] = []

            if shouldSaveCollection {
                let root = (try? await database.record(for: rootID)) ?? CKRecord(recordType: "Collection", recordID: rootID)
                root["name"] = collection.name as CKRecordValue; root["icon"] = collection.icon as CKRecordValue; root["subtitle"] = collection.subtitle as CKRecordValue; root["settingsJSON"] = settingsJSON(for: collection) as CKRecordValue; root["updatedAt"] = Date.now as CKRecordValue
                saving.append(root)
            }

            let itemIDs = Set(itemMutations.compactMap { $0.itemID ?? UUID(uuidString: $0.recordName) })
            let collectionItems = shouldBootstrap || shouldSaveCollection ? items.filter { $0.collectionID == collection.id } : items.filter { itemIDs.contains($0.id) }
            saving.append(contentsOf: collectionItems.map { record(for: $0, zoneID: zone, parent: rootID) })
            let eventItemIDs = Set(collectionItems.map(\.id))
            saving.append(contentsOf: events.filter { eventItemIDs.contains($0.itemID) }.map { record(for: $0, zoneID: zone, parent: rootID) })

            let collectionRatings = items.filter { $0.collectionID == collection.id }.flatMap(\.ratings)
            let collectionComments = items.filter { $0.collectionID == collection.id }.flatMap(\.comments)
            let ratingNames = Set(ratingMutations.filter { $0.operation != "delete" }.map(\.recordName))
            let commentNames = Set(commentMutations.filter { $0.operation != "delete" }.map(\.recordName))
            let ratingsToSave = shouldBootstrap || shouldSaveCollection ? collectionRatings : collectionRatings.filter { ratingNames.contains(CollaborationRecordNames.rating(itemID: $0.itemID, participantID: $0.participantID)) }
            let commentsToSave = shouldBootstrap || shouldSaveCollection ? collectionComments : collectionComments.filter { commentNames.contains(CollaborationRecordNames.comment($0.id)) }
            saving.append(contentsOf: ratingsToSave.map { record(for: $0, zoneID: zone, parent: CKRecord.ID(recordName: $0.itemID.uuidString, zoneID: zone)) })
            saving.append(contentsOf: commentsToSave.map { record(for: $0, zoneID: zone, parent: CKRecord.ID(recordName: $0.itemID.uuidString, zoneID: zone)) })
            if !saving.isEmpty { _ = try await database.modifyRecords(saving: saving, deleting: []) }

            for mutation in mutations where mutation.collectionID == collection.id && mutation.operation == "delete" {
                try? await database.deleteRecord(withID: CKRecord.ID(recordName: mutation.recordName, zoneID: zone))
            }
        }
    }

    private func fetchSnapshots(from database: CKDatabase) async throws -> [CloudCollectionSnapshot] {
        let zones = try await database.allRecordZones()
        var snapshots: [CloudCollectionSnapshot] = []
        for zone in zones where zone.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
            let query = CKQuery(recordType: "Collection", predicate: NSPredicate(value: true))
            let result = try await database.records(matching: query, inZoneWith: zone.zoneID, desiredKeys: nil, resultsLimit: 1000)
            for (_, match) in result.matchResults {
                guard case .success(let root) = match, let id = UUID(uuidString: root.recordID.recordName) else { continue }
                let itemQuery = CKQuery(recordType: "CollectionItem", predicate: NSPredicate(value: true))
                let itemResult = try await database.records(matching: itemQuery, inZoneWith: zone.zoneID, desiredKeys: nil, resultsLimit: 1000)
                let items = itemResult.matchResults.compactMap { (_, match) -> CollectionItem? in guard case .success(let record) = match else { return nil }; return item(from: record, collectionID: id) }
                let eventQuery = CKQuery(recordType: "CollectionEvent", predicate: NSPredicate(value: true))
                let eventResult = try await database.records(matching: eventQuery, inZoneWith: zone.zoneID, desiredKeys: nil, resultsLimit: 1000)
                let events = eventResult.matchResults.compactMap { (_, match) -> ItemEvent? in guard case .success(let record) = match else { return nil }; return event(from: record) }
                let ratingQuery = CKQuery(recordType: "CollectionItemRating", predicate: NSPredicate(value: true))
                let ratingResult = try await database.records(matching: ratingQuery, inZoneWith: zone.zoneID, desiredKeys: nil, resultsLimit: 1000)
                let ratings = ratingResult.matchResults.compactMap { (_, match) -> ItemRating? in guard case .success(let record) = match else { return nil }; return rating(from: record) }
                let commentQuery = CKQuery(recordType: "CollectionItemComment", predicate: NSPredicate(value: true))
                let commentResult = try await database.records(matching: commentQuery, inZoneWith: zone.zoneID, desiredKeys: nil, resultsLimit: 1000)
                let comments = commentResult.matchResults.compactMap { (_, match) -> ItemComment? in guard case .success(let record) = match else { return nil }; return comment(from: record) }
                let settings = decodeSettings(root["settingsJSON"] as? String)
                snapshots.append(CloudCollectionSnapshot(collection: CollectionModel(id: id, name: root["name"] as? String ?? "Collection", icon: root["icon"] as? String ?? "square.stack", subtitle: root["subtitle"] as? String ?? "Shared", category: settings.category, statuses: settings.statuses, mergedTags: settings.mergedTags, role: database.databaseScope == .shared ? .editor : .owner), items: items, events: events, ratings: ratings, comments: comments))
            }
        }
        return snapshots
    }

    private func settingsJSON(for collection: CollectionModel) -> String { let payload = CollectionSettingsPayload(category: collection.category, statuses: collection.statuses, mergedTags: collection.mergedTags); return (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "{}" }
    private func decodeSettings(_ string: String?) -> CollectionSettingsPayload { guard let string, let data = string.data(using: .utf8), let payload = try? JSONDecoder().decode(CollectionSettingsPayload.self, from: data) else { return CollectionSettingsPayload() }; return payload }
    private func zoneID(for collectionID: UUID) -> CKRecordZone.ID { CKRecordZone.ID(zoneName: "collection-\(collectionID.uuidString)", ownerName: CKCurrentUserDefaultName) }
    private func record(for item: CollectionItem, zoneID: CKRecordZone.ID, parent: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: "CollectionItem", recordID: CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID))
        record["collectionID"] = item.collectionID.uuidString as CKRecordValue; record["title"] = item.title as CKRecordValue; record["brand"] = item.brand as CKRecordValue; record["variant"] = item.variant as CKRecordValue; record["itemDescription"] = item.itemDescription as CKRecordValue; record["state"] = item.state.rawValue as CKRecordValue; record["quantity"] = item.quantity as CKRecordValue; record["createdAt"] = item.createdAt as CKRecordValue; record["updatedAt"] = item.updatedAt as CKRecordValue; if let consumedAt = item.consumedAt { record["consumedAt"] = consumedAt as CKRecordValue }; if let tags = try? String(data: JSONEncoder().encode(item.tags), encoding: .utf8) { record["tagsJSON"] = tags as CKRecordValue }; if let metadata = try? String(data: JSONEncoder().encode(item.metadata), encoding: .utf8) { record["metadataJSON"] = metadata as CKRecordValue }; if let barcode = item.barcode { record["barcodeValue"] = barcode.value as CKRecordValue; record["barcodeType"] = barcode.type as CKRecordValue }; record.parent = CKRecord.Reference(recordID: parent, action: .none); return record
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
    private func item(from record: CKRecord, collectionID: UUID) -> CollectionItem? { guard let id = UUID(uuidString: record.recordID.recordName), let title = record["title"] as? String else { return nil }; return CollectionItem(id: id, collectionID: collectionID, title: title, brand: record["brand"] as? String ?? "", variant: record["variant"] as? String ?? "", itemDescription: record["itemDescription"] as? String ?? "", state: ItemState(rawValue: record["state"] as? String ?? "wanted"), quantity: record["quantity"] as? Int ?? 1, barcode: (record["barcodeValue"] as? String).flatMap { Barcode(rawValue: $0, type: record["barcodeType"] as? String ?? "EAN-13") }, createdAt: record["createdAt"] as? Date ?? .now, updatedAt: record["updatedAt"] as? Date ?? .now, consumedAt: record["consumedAt"] as? Date, tags: decode(record["tagsJSON"] as? String, fallback: []), metadata: decode(record["metadataJSON"] as? String, fallback: [:]), imageSystemName: "shippingbox.fill", imageData: nil, importSourceKey: nil) }
    private func decode<T: Decodable>(_ string: String?, fallback: T) -> T { guard let string, let data = string.data(using: .utf8), let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }; return value }
}
