import Foundation
import OSLog
import SwiftData

extension Notification.Name {
    nonisolated static let collectionManagerLocalChanges = Notification.Name("CollectionManager.localChanges")
}

enum RepositoryFailurePoint { case fetch, save }

enum RepositoryError: LocalizedError, Sendable {
    case fetchFailed
    case saveFailed
    case permissionDenied
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .fetchFailed: "The local collection store could not be read."
        case .saveFailed: "The local collection store could not save this change."
        case .permissionDenied: "You do not have permission to change this collection."
        case .validation(let message): message
        }
    }
}

nonisolated private let repositoryLogger = Logger(subsystem: "de.holgerkrupp.CollectionManager", category: "persistence")

struct LocalSyncPayload: Sendable {
    let items: [CollectionItem]
    let events: [ItemEvent]
}

actor CollectionBackgroundRepository {
    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    func items(in collectionID: UUID) throws -> [CollectionItem] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let records = (try fetch(context, FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])))
        let ratings = (try fetch(context, FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let comments = (try fetch(context, FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == collectionID }, sortBy: [SortDescriptor(\.createdAt)])))
        let ratingsByItem = Dictionary(grouping: ratings, by: \.itemID)
        let commentsByItem = Dictionary(grouping: comments, by: \.itemID)
        return records.map { record in
            let tags = (try? JSONDecoder().decode([String].self, from: Data(record.tagsJSON.utf8))) ?? []
            let storedDates = (try? JSONDecoder().decode([String: Date].self, from: Data(record.dateTagsJSON.utf8))) ?? [:]
            let itemRatings = ratingsByItem[record.id, default: []].map { ItemRating(id: $0.id, itemID: $0.itemID, participantID: $0.participantID, participantName: $0.participantName, value: $0.value, updatedAt: $0.updatedAt) }.sorted { $0.participantName.localizedStandardCompare($1.participantName) == .orderedAscending }
            let itemComments = commentsByItem[record.id, default: []].map { ItemComment(id: $0.id, itemID: $0.itemID, participantID: $0.participantID, participantName: $0.participantName, text: $0.text, createdAt: $0.createdAt, updatedAt: $0.updatedAt) }
            let sourceSnapshot = record.sourceSnapshotJSON.flatMap { try? JSONDecoder().decode(ProductSourceSnapshot.self, from: Data($0.utf8)) }
            return CollectionItem(id: record.id, collectionID: record.collectionID, title: record.title, brand: record.brand, variant: record.variant, itemDescription: record.itemDescription, state: ItemState(rawValue: record.stateRawValue), quantity: record.quantity, barcode: record.barcodeValue.flatMap { Barcode(rawValue: $0, type: record.barcodeType ?? "EAN-13") }, createdAt: record.createdAt, updatedAt: record.updatedAt, consumedAt: record.consumedAt, tags: tags, metadata: (try? JSONDecoder().decode([String: MetadataValue].self, from: Data(record.metadataJSON.utf8))) ?? [:], imageSystemName: record.imageSystemName, imageData: record.imageData, importSourceKey: record.importSourceKey, sourceSnapshot: sourceSnapshot, dateTags: storedDates, ratings: itemRatings, comments: itemComments)
        }
    }

    func syncPayload(collectionIDs: [UUID]) throws -> LocalSyncPayload {
        var allItems: [CollectionItem] = []
        for collectionID in collectionIDs { allItems.append(contentsOf: try items(in: collectionID)) }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let collectionIDSet = Set(collectionIDs)
        let events = ((try fetch(context, FetchDescriptor<EventRecord>(sortBy: [SortDescriptor(\.timestamp)])))).filter { collectionIDSet.contains($0.collectionID) }.map { ItemEvent(id: $0.id, itemID: $0.itemID, timestamp: $0.timestamp, type: $0.type, note: $0.note) }
        return LocalSyncPayload(items: allItems, events: events)
    }

    func deleteItem(id itemID: UUID, collectionID: UUID) throws -> Bool {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard try canEdit(collectionID, context: context) else { throw RepositoryError.permissionDenied }
        // An item that is already gone from the store is a successful delete,
        // not a failure. Reporting false here made a repeated delete look
        // broken and put the row back into the list.
        guard let item = try fetch(context, FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.id == itemID })).first else { return true }
        guard item.collectionID == collectionID else { throw RepositoryError.permissionDenied }
        let ratings = (try fetch(context, FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.itemID == itemID })))
        let comments = (try fetch(context, FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.itemID == itemID })))
        let events = (try fetch(context, FetchDescriptor<EventRecord>(predicate: #Predicate { $0.itemID == itemID })))
        for rating in ratings {
            context.delete(rating)
            enqueue(context: context, collectionID: collectionID, itemID: itemID, recordName: itemID.uuidString + "-rating-" + rating.participantID, recordType: "CollectionItemRating", operation: "delete")
        }
        for comment in comments {
            context.delete(comment)
            enqueue(context: context, collectionID: collectionID, itemID: itemID, recordName: comment.id.uuidString, recordType: "CollectionItemComment", operation: "delete")
        }
        for event in events {
            context.delete(event)
            enqueue(context: context, collectionID: collectionID, itemID: itemID, recordName: event.id.uuidString, recordType: "CollectionEvent", operation: "delete")
        }
        context.delete(item)
        enqueue(context: context, collectionID: collectionID, itemID: itemID, recordName: itemID.uuidString, recordType: "CollectionItem", operation: "delete")
        do {
            try context.save()
            NotificationCenter.default.post(name: .collectionManagerLocalChanges, object: nil)
            return true
        } catch {
            context.rollback()
            repositoryLogger.error("Background delete failed; transaction rolled back: \(String(describing: type(of: error)), privacy: .public)")
            throw RepositoryError.saveFailed
        }
    }

    func deleteAllItems(in collectionID: UUID) throws -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard try canEdit(collectionID, context: context) else { throw RepositoryError.permissionDenied }
        let items = (try fetch(context, FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let events = (try fetch(context, FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let ratings = (try fetch(context, FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let comments = (try fetch(context, FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        for item in items {
            context.delete(item)
            enqueue(context: context, collectionID: collectionID, itemID: item.id, recordName: item.id.uuidString, recordType: "CollectionItem", operation: "delete")
        }
        for event in events {
            context.delete(event)
            enqueue(context: context, collectionID: collectionID, itemID: event.itemID, recordName: event.id.uuidString, recordType: "CollectionEvent", operation: "delete")
        }
        for rating in ratings {
            context.delete(rating)
            enqueue(context: context, collectionID: collectionID, itemID: rating.itemID, recordName: rating.itemID.uuidString + "-rating-" + rating.participantID, recordType: "CollectionItemRating", operation: "delete")
        }
        for comment in comments {
            context.delete(comment)
            enqueue(context: context, collectionID: collectionID, itemID: comment.itemID, recordName: comment.id.uuidString, recordType: "CollectionItemComment", operation: "delete")
        }
        guard !items.isEmpty || !events.isEmpty || !ratings.isEmpty || !comments.isEmpty else { return 0 }
        do {
            try context.save()
            NotificationCenter.default.post(name: .collectionManagerLocalChanges, object: nil)
            return items.count
        } catch {
            context.rollback()
            repositoryLogger.error("Background bulk delete failed; transaction rolled back: \(String(describing: type(of: error)), privacy: .public)")
            throw RepositoryError.saveFailed
        }
    }

    func deleteCollection(id collectionID: UUID) throws -> Bool {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = collectionID
        let role = (try fetch(context, FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == id })).first(where: { !$0.participantID.hasPrefix("share:") })?.roleRawValue) ?? "viewer"
        guard role == "owner" else { throw RepositoryError.permissionDenied }
        guard let collection = try fetch(context, FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == id })).first else { return true }
        let items = (try fetch(context, FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == id })))
        let ratings = (try fetch(context, FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == id })))
        let comments = (try fetch(context, FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == id })))
        let events = (try fetch(context, FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == id })))
        let webSyncs = (try fetch(context, FetchDescriptor<WebSyncRecord>(predicate: #Predicate { $0.collectionID == id })))
        let members = (try fetch(context, FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == id })))
        let mutations = (try fetch(context, FetchDescriptor<SyncMutationRecord>(predicate: #Predicate { $0.collectionID == id })))
        let syncStates = (try fetch(context, FetchDescriptor<CloudSyncStateRecord>(predicate: #Predicate { $0.collectionID == id })))
        items.forEach(context.delete); ratings.forEach(context.delete); comments.forEach(context.delete); events.forEach(context.delete); webSyncs.forEach(context.delete); members.forEach(context.delete); mutations.forEach(context.delete); syncStates.forEach(context.delete)
        // CKRecord parents use .none, so deleting the root does not cascade
        // remotely. Preserve explicit tombstones for every removed child.
        for item in items { enqueue(context: context, collectionID: id, itemID: item.id, recordName: item.id.uuidString, recordType: "CollectionItem", operation: "delete") }
        for rating in ratings { enqueue(context: context, collectionID: id, itemID: rating.itemID, recordName: "\(rating.itemID.uuidString)-rating-\(rating.participantID)", recordType: "CollectionItemRating", operation: "delete") }
        for comment in comments { enqueue(context: context, collectionID: id, itemID: comment.itemID, recordName: comment.id.uuidString, recordType: "CollectionItemComment", operation: "delete") }
        for event in events { enqueue(context: context, collectionID: id, itemID: event.itemID, recordName: event.id.uuidString, recordType: "CollectionEvent", operation: "delete") }
        context.delete(collection)
        enqueue(context: context, collectionID: id, itemID: nil, recordName: id.uuidString, recordType: "Collection", operation: "delete")
        do {
            try context.save()
            NotificationCenter.default.post(name: .collectionManagerLocalChanges, object: nil)
            return true
        } catch {
            context.rollback()
            repositoryLogger.error("Background collection delete failed; transaction rolled back: \(String(describing: type(of: error)), privacy: .public)")
            throw RepositoryError.saveFailed
        }
    }

    private func canEdit(_ collectionID: UUID, context: ModelContext) throws -> Bool {
        let id = collectionID
        let role = (try fetch(context, FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == id })).first(where: { !$0.participantID.hasPrefix("share:") })?.roleRawValue) ?? "viewer"
        return role == "owner" || role == "editor"
    }

    private func fetch<T: PersistentModel>(_ context: ModelContext, _ descriptor: FetchDescriptor<T>) throws -> [T] {
        do { return try context.fetch(descriptor) }
        catch { throw RepositoryError.fetchFailed }
    }

    private func enqueue(context: ModelContext, collectionID: UUID, itemID: UUID?, recordName: String, recordType: String, operation: String) {
        context.insert(SyncMutationRecord(collectionID: collectionID, itemID: itemID, recordName: recordName, recordType: recordType, operation: operation))
    }
}

@MainActor final class CollectionRepository {
    private let context: ModelContext
    var failureInjector: ((RepositoryFailurePoint) throws -> Void)?
    private(set) var lastPersistenceError: RepositoryError?
    init(context: ModelContext) { self.context = context; context.autosaveEnabled = false }
    func collections() throws -> [CollectionModel] {
        let records = (try fetch(FetchDescriptor<CollectionRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])))
        let members = (try fetch(FetchDescriptor<CollectionMemberRecord>()))
        var roles: [UUID: CollectionMemberRole] = [:]
        for member in members where !member.participantID.hasPrefix("share:") && roles[member.collectionID] == nil { roles[member.collectionID] = member.role }
        let names = Dictionary(grouping: members.filter { $0.participantID.hasPrefix("share:") && !$0.displayName.isEmpty }, by: \.collectionID)
        return records.map { record in
            var collection = model(from: record, role: roles[record.id] ?? .viewer)
            collection.sharedWith = names[record.id, default: []].map(\.displayName).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return collection
        }
    }
    private func model(from record: CollectionRecord, role: CollectionMemberRole = .owner) -> CollectionModel {
        let data = Data(record.settingsJSON.utf8)
        let payload: CollectionSettingsPayload
        if let decoded = try? JSONDecoder().decode(CollectionSettingsPayload.self, from: data) {
            payload = decoded
        } else {
            let labels = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            payload = CollectionSettingsPayload(statuses: CollectionStatus.defaults.map { status in
                var updated = status
                updated.name = labels[status.id] ?? status.name
                return updated
            })
        }
        let statuses = payload.statuses.isEmpty ? CollectionStatus.defaults : payload.statuses
        let defaultStatusID = statuses.contains(where: { $0.id == payload.defaultStatusID }) ? (payload.defaultStatusID ?? statuses[0].id) : statuses[0].id
        return CollectionModel(id: record.id, name: record.name, icon: record.icon, subtitle: record.subtitle, category: payload.category, statuses: statuses, mergedTags: payload.mergedTags, metadataFields: payload.metadataFields, defaultStatusID: defaultStatusID, barcodeRequired: payload.barcodeRequired, role: role)
    }
    private func mergedTags(for collectionID: UUID) throws -> [MergedTagRule] {
        let id = collectionID
        guard let record = try fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == id })).first else { return [] }
        return (try? JSONDecoder().decode(CollectionSettingsPayload.self, from: Data(record.settingsJSON.utf8)))?.mergedTags ?? []
    }
    func items(in collectionID: UUID) throws -> [CollectionItem] {
        let descriptor = FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let records = (try fetch(descriptor))
        let ratingRecords = (try fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let commentRecords = (try fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == collectionID }, sortBy: [SortDescriptor(\.createdAt)])))
        let ratingsByItem = Dictionary(grouping: ratingRecords.map(\.domain), by: \.itemID)
        let commentsByItem = Dictionary(grouping: commentRecords.map(\.domain), by: \.itemID)
        let items = records.map { record in
            var item = record.domain
            item.ratings = ratingsByItem[item.id, default: []].sorted { $0.participantName.localizedStandardCompare($1.participantName) == .orderedAscending }
            item.comments = commentsByItem[item.id, default: []]
            return item
        }
        return items
    }
    func item(id itemID: UUID, in collectionID: UUID? = nil) throws -> CollectionItem? {
        guard let record = try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.id == itemID })).first else { return nil }
        if let collectionID, record.collectionID != collectionID { return nil }
        var item = record.domain
        item.ratings = ((try fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.itemID == itemID })))).map(\.domain).sorted { $0.participantName.localizedStandardCompare($1.participantName) == .orderedAscending }
        item.comments = ((try fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.itemID == itemID }, sortBy: [SortDescriptor(\.createdAt)])))).map(\.domain)
        return item
    }
    func addCollection(name: String, icon: String, subtitle: String, category: CollectionCategory = .custom) throws { let record = CollectionRecord(name: name, icon: icon, subtitle: subtitle, settingsJSON: (try? String(data: JSONEncoder().encode(CollectionSettingsPayload(category: category)), encoding: .utf8)) ?? "{}"); context.insert(record); context.insert(CollectionMemberRecord(collectionID: record.id, participantID: "local", role: .owner)); enqueue(collectionID: record.id, recordName: record.id.uuidString, recordType: "Collection", operation: "createCollection"); try save() }
    func deleteCollection(_ collection: CollectionModel) throws {
        guard try role(for: collection.id).canDelete else { throw RepositoryError.permissionDenied }
        let collectionID = collection.id
        guard let record = try fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == collectionID })).first else { return }
        let items = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let ratings = (try fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let comments = (try fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let events = (try fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let webSyncs = (try fetch(FetchDescriptor<WebSyncRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let members = (try fetch(FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let mutations = (try fetch(FetchDescriptor<SyncMutationRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let syncStates = (try fetch(FetchDescriptor<CloudSyncStateRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        items.forEach(context.delete); ratings.forEach(context.delete); comments.forEach(context.delete); events.forEach(context.delete); webSyncs.forEach(context.delete); members.forEach(context.delete); mutations.forEach(context.delete); syncStates.forEach(context.delete)
        enqueue(collectionID: collectionID, recordName: collectionID.uuidString, recordType: "Collection", operation: "delete")
        context.delete(record)
        try save()
    }
    func updateCollection(_ collection: CollectionModel) throws {
        guard try role(for: collection.id).canEdit else { throw RepositoryError.permissionDenied }
        let collectionID = collection.id
        guard let record = try fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == collectionID })).first else { return }
        record.name = collection.name; record.icon = collection.icon; record.subtitle = collection.subtitle; record.updatedAt = .now
        let statuses = collection.statuses.isEmpty ? CollectionStatus.defaults : collection.statuses
        let defaultStatusID = statuses.contains(where: { $0.id == collection.defaultStatusID }) ? collection.defaultStatusID : statuses[0].id
        let payload = CollectionSettingsPayload(category: collection.category, statuses: statuses, mergedTags: collection.mergedTags, metadataFields: collection.metadataFields, defaultStatusID: defaultStatusID, barcodeRequired: collection.barcodeRequired)
        record.settingsJSON = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "{}"

        // Items keep the status ID, so removing a status must not leave items
        // pointing at a status that can no longer be selected or displayed.
        let validStatusIDs = Set(statuses.map(\.id))
        let records = try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }))
        if !statuses.isEmpty {
            for item in records where !validStatusIDs.contains(item.stateRawValue) {
                item.stateRawValue = defaultStatusID
                item.updatedAt = .now
            }
        }
        enqueue(collectionID: collection.id, recordName: collection.id.uuidString, recordType: "Collection")
        try save()
    }
    @discardableResult
    func addItem(_ item: CollectionItem, allowsDuplicates: Bool = false) throws -> Bool {
        guard try role(for: item.collectionID).canEdit else { throw RepositoryError.permissionDenied }
        let collectionID = item.collectionID
        if !allowsDuplicates {
            let identity = importIdentity(title: item.title, brand: item.brand, variant: item.variant)
            let records = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
            guard !records.contains(where: { importIdentity(title: $0.title, brand: $0.brand, variant: $0.variant) == identity }) else { return false }
        }
        var item = item
        try validateCreation(barcode: item.barcode, collectionID: collectionID)
        try validatePayload(metadata: item.metadata, dates: [item.createdAt, item.updatedAt] + Array(item.dateTags.values) + [item.consumedAt].compactMap { $0 }, sourceSnapshot: item.sourceSnapshot)
        item.state = normalizedState(item.state, settings: try collectionSettings(for: collectionID))
        item.tags = TagUtilities.applyingMergedTags(item.tags, rules: try mergedTags(for: item.collectionID))
        context.insert(ItemRecord(from: item))
        context.insert(EventRecord(itemID: item.id, collectionID: item.collectionID, type: "created"))
        enqueue(collectionID: item.collectionID, recordName: item.id.uuidString, recordType: "CollectionItem")
        return try save()
    }
    func webSyncs(for collectionID: UUID) throws -> [WebSyncRecord] { (try fetch(FetchDescriptor<WebSyncRecord>(predicate: #Predicate { $0.collectionID == collectionID }, sortBy: [SortDescriptor(\.urlString)]))) }
    func collectionName(for collectionID: UUID) throws -> String {
        let id = collectionID
        return (try fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == id })).first?.name) ?? "Collection"
    }
    func metadataFields(for collectionID: UUID) throws -> [MetadataFieldDefinition] {
        let id = collectionID
        guard let record = try fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == id })).first else { return [] }
        return model(from: record).metadataFields
    }
    func statuses(for collectionID: UUID) throws -> [CollectionStatus] {
        let id = collectionID
        guard let record = try fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == id })).first else { return [] }
        return model(from: record).statuses
    }
    func addWebSync(_ sync: WebSyncRecord) throws { guard try role(for: sync.collectionID).canEdit else { throw RepositoryError.permissionDenied }; context.insert(sync); try save() }
    func updateWebSync(_ sync: WebSyncRecord) throws { guard try role(for: sync.collectionID).canEdit else { context.rollback(); throw RepositoryError.permissionDenied }; try save() }
    func deleteWebSync(_ sync: WebSyncRecord) throws { guard try role(for: sync.collectionID).canEdit else { throw RepositoryError.permissionDenied }; context.delete(sync); try save() }
    func setWebSync(_ sync: WebSyncRecord, lastSyncAt: Date?, error: String?) throws { sync.lastSyncAt = lastSyncAt; sync.lastError = error; try save() }
    func hasImportedItem(collectionID: UUID, sourceKey: String) throws -> Bool {
        let normalizedSource = importSourceIdentity(sourceKey)
        let records = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        return records.contains { $0.importSourceKey.map(importSourceIdentity) == normalizedSource }
    }
    func importedSourceKeys(in collectionID: UUID) throws -> Set<String> {
        let records = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        return Set(records.compactMap(\.importSourceKey).map(importSourceIdentity))
    }
    func importDraft(_ draft: ImportDraft, collectionID: UUID, sourceKey: String) throws -> Bool {
        let before = try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })).count
        try importDrafts([(draft: draft, sourceKey: sourceKey)], collectionID: collectionID)
        return try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })).count > before
    }
    func importDrafts(_ drafts: [(draft: ImportDraft, sourceKey: String)], collectionID: UUID) throws {
        guard try role(for: collectionID).canEdit else { throw RepositoryError.permissionDenied }; guard !drafts.isEmpty else { return }
        let records = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let settings = try collectionSettings(for: collectionID)
        for entry in drafts { try validatePayload(metadata: entry.draft.metadata) }
        if settings.barcodeRequired {
            for entry in drafts {
                let identity = importIdentity(title: entry.draft.title, brand: entry.draft.brand, variant: entry.draft.variant)
                let existing = records.first { $0.importSourceKey.map(importSourceIdentity) == importSourceIdentity(entry.sourceKey) || importIdentity(title: $0.title, brand: $0.brand, variant: $0.variant) == identity }
                guard entry.draft.barcode != nil || existing?.barcodeValue != nil else { throw RepositoryError.validation("This collection requires a barcode for every item.") }
            }
        }
        let rules = try mergedTags(for: collectionID)
        var bySource: [String: ItemRecord] = [:]
        for record in records {
            if let sourceKey = record.importSourceKey.map(importSourceIdentity), bySource[sourceKey] == nil { bySource[sourceKey] = record }
        }
        var byIdentity: [String: ItemRecord] = [:]
        for record in records { byIdentity[importIdentity(title: record.title, brand: record.brand, variant: record.variant)] = record }

        for entry in drafts {
            var draft = entry.draft
            draft.state = normalizedState(draft.state, wasExplicit: draft.stateWasExplicit, settings: settings)
            let sourceIdentity = importSourceIdentity(entry.sourceKey)
            let existing = bySource[sourceIdentity] ?? byIdentity[importIdentity(title: draft.title, brand: draft.brand, variant: draft.variant)]
            if let existing {
                let previous = existing.domain
                var item = previous
                item.title = draft.title; item.brand = draft.brand; item.variant = draft.variant; item.itemDescription = draft.description; item.state = draft.state; item.quantity = draft.quantity; item.tags = TagUtilities.applyingMergedTags(draft.tags, rules: rules); item.barcode = draft.barcode ?? item.barcode; item.metadata.merge(draft.metadata) { _, imported in imported }; item.importSourceKey = entry.sourceKey; item.updatedAt = .now
                existing.update(from: item)
                context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: previous.state == item.state ? "imported" : "importedStateChanged"))
                bySource[sourceIdentity] = existing
                byIdentity[importIdentity(title: item.title, brand: item.brand, variant: item.variant)] = existing
            } else {
                let item = CollectionItem(id: UUID(), collectionID: collectionID, title: draft.title, brand: draft.brand, variant: draft.variant, itemDescription: draft.description, state: draft.state, quantity: draft.quantity, barcode: draft.barcode, createdAt: .now, updatedAt: .now, consumedAt: draft.state == .consumed ? .now : nil, tags: TagUtilities.applyingMergedTags(draft.tags, rules: rules), metadata: draft.metadata, imageSystemName: "shippingbox.fill", imageData: nil, importSourceKey: entry.sourceKey)
                let record = ItemRecord(from: item)
                context.insert(record); context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "created")); context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "imported")); enqueue(collectionID: collectionID, recordName: item.id.uuidString, recordType: "CollectionItem")
                bySource[sourceIdentity] = record
                byIdentity[importIdentity(title: item.title, brand: item.brand, variant: item.variant)] = record
            }
        }
        try save()
    }
    /// New-item imports preserve the review's duplicate policy in one commit.
    func importNewDrafts(_ drafts: [ImportDraft], collectionID: UUID, allowsDuplicates: Bool) throws {
        guard try role(for: collectionID).canEdit else { throw RepositoryError.permissionDenied }
        let settings = try collectionSettings(for: collectionID)
        for draft in drafts {
            try validatePayload(metadata: draft.metadata)
            try validateCreation(barcode: draft.barcode, collectionID: collectionID)
        }
        let rules = try mergedTags(for: collectionID)
        var identities: Set<String> = []
        if !allowsDuplicates {
            identities = Set(try items(in: collectionID).map { importIdentity(title: $0.title, brand: $0.brand, variant: $0.variant) })
        }
        for draft in drafts {
            let identity = importIdentity(title: draft.title, brand: draft.brand, variant: draft.variant)
            if !allowsDuplicates && !identities.insert(identity).inserted { continue }
            let state = normalizedState(draft.state, wasExplicit: draft.stateWasExplicit, settings: settings)
            let item = CollectionItem(id: UUID(), collectionID: collectionID, title: draft.title, brand: draft.brand, variant: draft.variant, itemDescription: draft.description, state: state, quantity: draft.quantity, barcode: draft.barcode, createdAt: .now, updatedAt: .now, consumedAt: state == .consumed ? .now : nil, tags: TagUtilities.applyingMergedTags(draft.tags, rules: rules), metadata: draft.metadata, imageSystemName: "shippingbox.fill", imageData: nil, importSourceKey: draft.sourceIdentifier)
            context.insert(ItemRecord(from: item))
            context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "created"))
            context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "imported"))
        }
        try save()
    }

    func deduplicateItems(in collectionID: UUID) throws -> Int {
        guard try role(for: collectionID).canEdit else { throw RepositoryError.permissionDenied }
        let records = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])))
        var seenSources = Set<String>()
        var seenItems = Set<String>()
        var duplicateIDs = Set<UUID>()
        for record in records {
            let source = record.importSourceKey.map(importSourceIdentity).flatMap { $0.isEmpty ? nil : $0 }
            let identity = importIdentity(title: record.title, brand: record.brand, variant: record.variant)
            let isDuplicate = source.map(seenSources.contains) == true || seenItems.contains(identity)
            if isDuplicate {
                duplicateIDs.insert(record.id)
            } else {
                if let source { seenSources.insert(source) }
                seenItems.insert(identity)
            }
        }
        guard !duplicateIDs.isEmpty else { return 0 }

        let events = (try fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let ratings = (try fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let comments = (try fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        for record in records where duplicateIDs.contains(record.id) {
            context.delete(record)
            enqueue(collectionID: collectionID, recordName: record.id.uuidString, recordType: "CollectionItem", operation: "delete")
        }
        for event in events where duplicateIDs.contains(event.itemID) { context.delete(event) }
        for rating in ratings where duplicateIDs.contains(rating.itemID) {
            context.delete(rating)
            enqueue(collectionID: collectionID, itemID: rating.itemID, recordName: CollaborationRecordNames.rating(itemID: rating.itemID, participantID: rating.participantID), recordType: "CollectionItemRating", operation: "delete")
        }
        for comment in comments where duplicateIDs.contains(comment.itemID) {
            context.delete(comment)
            enqueue(collectionID: collectionID, itemID: comment.itemID, recordName: CollaborationRecordNames.comment(comment.id), recordType: "CollectionItemComment", operation: "delete")
        }
        try save()
        return duplicateIDs.count
    }
    func deleteAllImportedItems(in collectionID: UUID) throws -> Int {
        guard try role(for: collectionID).canEdit else { throw RepositoryError.permissionDenied }
        let records = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let imported = records.filter { !($0.importSourceKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        for record in imported { context.delete(record); enqueue(collectionID: collectionID, recordName: record.id.uuidString, recordType: "CollectionItem", operation: "delete") }
        if !imported.isEmpty { try save() }; return imported.count
    }
    func applyTagRules(_ options: TagGenerationOptions, in collectionID: UUID) throws -> Int {
        guard try role(for: collectionID).canEdit else { throw RepositoryError.permissionDenied }
        let records = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        var changed = 0
        for record in records {
            let item = record.domain
            let rawTags = options.keepExistingTags ? item.tags.joined(separator: options.separators.first.map(String.init) ?? ",") : ""
            let tags = TagUtilities.applyingMergedTags(TagUtilities.tags(title: item.title, existing: item.tags, rawTags: rawTags, options: options), rules: try mergedTags(for: collectionID))
            guard tags != item.tags else { continue }
            var updated = item; updated.tags = tags; updated.updatedAt = .now
            record.update(from: updated); changed += 1
        }
        if changed > 0 { try save() }
        return changed
    }
    func applyMergedTags(in collectionID: UUID) throws -> Int {
        guard try role(for: collectionID).canEdit else { throw RepositoryError.permissionDenied }
        let records = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let rules = try mergedTags(for: collectionID)
        var changed = 0
        for record in records {
            let item = record.domain
            let tags = TagUtilities.applyingMergedTags(item.tags, rules: rules)
            guard tags != item.tags else { continue }
            var updated = item; updated.tags = tags; updated.updatedAt = .now
            record.update(from: updated); changed += 1
        }
        if changed > 0 { try save() }
        return changed
    }
    func applyWebDraft(_ draft: ImportDraft, collectionID: UUID, sourceKey: String, updateExistingState: Bool) throws -> Bool {
        try applyWebDrafts([(draft: draft, sourceKey: sourceKey, updateExistingState: updateExistingState)], collectionID: collectionID).added > 0
    }
    func applyWebDrafts(_ drafts: [(draft: ImportDraft, sourceKey: String, updateExistingState: Bool)], collectionID: UUID) throws -> WebSyncApplyResult {
        guard try role(for: collectionID).canEdit else { throw RepositoryError.permissionDenied }; guard !drafts.isEmpty else { return WebSyncApplyResult() }
        let records = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let settings = try collectionSettings(for: collectionID)
        for entry in drafts { try validatePayload(metadata: entry.draft.metadata) }
        if settings.barcodeRequired {
            for entry in drafts {
                let identity = importIdentity(title: entry.draft.title, brand: entry.draft.brand, variant: entry.draft.variant)
                let existing = records.first { $0.importSourceKey.map(importSourceIdentity) == importSourceIdentity(entry.sourceKey) || importIdentity(title: $0.title, brand: $0.brand, variant: $0.variant) == identity }
                guard entry.draft.barcode != nil || existing?.barcodeValue != nil else { throw RepositoryError.validation("This collection requires a barcode for every item.") }
            }
        }
        let rules = try mergedTags(for: collectionID)
        var bySource: [String: ItemRecord] = [:]
        for record in records {
            if let sourceKey = record.importSourceKey.map(importSourceIdentity), bySource[sourceKey] == nil { bySource[sourceKey] = record }
        }
        var byIdentity: [String: ItemRecord] = [:]
        for record in records { byIdentity[importIdentity(title: record.title, brand: record.brand, variant: record.variant)] = record }
        var added = 0
        var updated = 0
        var addedItems: [String] = []
        var matchedStateChanges: [AutomaticSyncStateChange] = []

        for entry in drafts {
            var draft = entry.draft
            draft.state = normalizedState(draft.state, wasExplicit: draft.stateWasExplicit, settings: settings)
            let sourceIdentity = importSourceIdentity(entry.sourceKey)
            let itemIdentity = importIdentity(title: draft.title, brand: draft.brand, variant: draft.variant)
            if let existing = bySource[sourceIdentity] ?? byIdentity[itemIdentity] {
                let previous = existing.domain
                var item = previous
                item.title = draft.title; item.brand = draft.brand; item.variant = draft.variant; item.itemDescription = draft.description; item.quantity = draft.quantity; item.tags = TagUtilities.applyingMergedTags(draft.tags, rules: rules); item.barcode = draft.barcode ?? item.barcode; item.metadata.merge(draft.metadata) { _, imported in imported }; item.importSourceKey = entry.sourceKey
                if entry.updateExistingState { item.state = draft.state; item.consumedAt = draft.state == .consumed ? (item.consumedAt ?? .now) : nil }
                item.updatedAt = .now
                existing.update(from: item)
                context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: entry.updateExistingState && previous.state != item.state ? "importedStateChanged" : "imported"))
                if entry.updateExistingState, previous.state != item.state {
                    matchedStateChanges.append(AutomaticSyncStateChange(title: item.title, newState: item.state))
                }
                bySource[sourceIdentity] = existing
                byIdentity[importIdentity(title: item.title, brand: item.brand, variant: item.variant)] = existing
                updated += 1
            } else {
                let item = CollectionItem(id: UUID(), collectionID: collectionID, title: draft.title, brand: draft.brand, variant: draft.variant, itemDescription: draft.description, state: draft.state, quantity: draft.quantity, barcode: draft.barcode, createdAt: .now, updatedAt: .now, consumedAt: draft.state == .consumed ? .now : nil, tags: TagUtilities.applyingMergedTags(draft.tags, rules: rules), metadata: draft.metadata, imageSystemName: "shippingbox.fill", imageData: nil, importSourceKey: entry.sourceKey)
                let record = ItemRecord(from: item)
                context.insert(record); context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "created")); context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "imported")); enqueue(collectionID: collectionID, recordName: item.id.uuidString, recordType: "CollectionItem")
                bySource[sourceIdentity] = record
                byIdentity[itemIdentity] = record
                added += 1
                addedItems.append(item.title)
            }
        }
        try save()
        return WebSyncApplyResult(added: added, updated: updated, addedItems: addedItems, matchedStateChanges: matchedStateChanges)
    }
    func updateItem(_ item: CollectionItem, previousState: ItemState? = nil) throws {
        guard try role(for: item.collectionID).canEdit else { throw RepositoryError.permissionDenied }
        let record = try requireItem(item.id, in: item.collectionID)
        try validatePayload(metadata: item.metadata, dates: [item.createdAt, item.updatedAt] + Array(item.dateTags.values) + [item.consumedAt].compactMap { $0 }, sourceSnapshot: item.sourceSnapshot)
        var item = item
        item.state = normalizedState(item.state, settings: try collectionSettings(for: item.collectionID))
        item.tags = TagUtilities.applyingMergedTags(item.tags, rules: try mergedTags(for: item.collectionID))
        record.update(from: item)
        if let previousState, previousState != item.state { context.insert(EventRecord(itemID: item.id, collectionID: item.collectionID, type: "stateChanged", note: "\(previousState.label) → \(item.state.label)")) }
        enqueue(collectionID: item.collectionID, recordName: item.id.uuidString, recordType: "CollectionItem")
        try save()
    }
    @discardableResult func bulkUpdateState(for itemIDs: Set<UUID>, in collectionID: UUID, to state: ItemState) throws -> Int {
        guard try role(for: collectionID).canEdit else { throw RepositoryError.permissionDenied }; guard !itemIDs.isEmpty else { return 0 }
        let state = normalizedState(state, settings: try collectionSettings(for: collectionID))
        let records = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        var changed = 0
        for record in records where itemIDs.contains(record.id) {
            let previousState = ItemState(rawValue: record.stateRawValue)
            guard previousState != state else { continue }
            var item = record.domain
            item.state = state
            item.consumedAt = state == .consumed ? (item.consumedAt ?? .now) : nil
            item.updatedAt = .now
            record.update(from: item)
            context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "stateChanged", note: "\(previousState.label) → \(state.label)"))
            enqueue(collectionID: collectionID, recordName: item.id.uuidString, recordType: "CollectionItem")
            changed += 1
        }
        if changed > 0 { try save() }
        return changed
    }
    func setRating(for item: CollectionItem, value: Int?, participant: CollaboratorIdentity) throws {
        guard try role(for: item.collectionID).canEdit else { throw RepositoryError.permissionDenied }
        _ = try requireItem(item.id, in: item.collectionID)
        let itemID = item.id; let participantID = participant.id
        let existing = try fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.itemID == itemID && $0.participantID == participantID })).first
        let recordName = CollaborationRecordNames.rating(itemID: item.id, participantID: participant.id)
        if let value, (1...5).contains(value) {
            if let existing { existing.value = value; existing.participantName = participant.displayName; existing.updatedAt = .now }
            else { context.insert(ItemRatingRecord(itemID: item.id, collectionID: item.collectionID, participantID: participant.id, participantName: participant.displayName, value: value)) }
            enqueue(collectionID: item.collectionID, itemID: item.id, recordName: recordName, recordType: "CollectionItemRating")
        } else if let existing {
            context.delete(existing)
            enqueue(collectionID: item.collectionID, itemID: item.id, recordName: recordName, recordType: "CollectionItemRating", operation: "delete")
        }
        try save()
    }
    @discardableResult func addComment(to item: CollectionItem, text: String, participant: CollaboratorIdentity) throws -> ItemComment? {
        guard try role(for: item.collectionID).canEdit else { throw RepositoryError.permissionDenied }
        _ = try requireItem(item.id, in: item.collectionID)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let record = ItemCommentRecord(itemID: item.id, collectionID: item.collectionID, participantID: participant.id, participantName: participant.displayName, text: trimmed)
        context.insert(record)
        enqueue(collectionID: item.collectionID, itemID: item.id, recordName: CollaborationRecordNames.comment(record.id), recordType: "CollectionItemComment")
        try save()
        return record.domain
    }
    func deleteItem(_ item: CollectionItem) throws {
        guard try role(for: item.collectionID).canEdit else { throw RepositoryError.permissionDenied }
        let itemID = item.id
        guard let record = try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.id == itemID })).first else { return }
        guard record.collectionID == item.collectionID else { throw RepositoryError.permissionDenied }
        try purgeItemChildren(itemID: itemID)
        context.delete(record)
        try save()
    }
    func deleteAllItems(in collectionID: UUID) throws -> Int {
        guard try role(for: collectionID).canEdit else { throw RepositoryError.permissionDenied }
        let items = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let events = (try fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let ratings = (try fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        let comments = (try fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
        for item in items { context.delete(item); enqueue(collectionID: collectionID, recordName: item.id.uuidString, recordType: "CollectionItem", operation: "delete") }
        for rating in ratings { context.delete(rating); enqueue(collectionID: collectionID, itemID: rating.itemID, recordName: CollaborationRecordNames.rating(itemID: rating.itemID, participantID: rating.participantID), recordType: "CollectionItemRating", operation: "delete") }
        for comment in comments { context.delete(comment); enqueue(collectionID: collectionID, itemID: comment.itemID, recordName: CollaborationRecordNames.comment(comment.id), recordType: "CollectionItemComment", operation: "delete") }
        events.forEach(context.delete)
        if !items.isEmpty || !events.isEmpty { try save() }
        return items.count
    }
    func events(for item: CollectionItem) throws -> [ItemEvent] { let itemID = item.id; let d = FetchDescriptor<EventRecord>(predicate: #Predicate { $0.itemID == itemID }, sortBy: [SortDescriptor(\.timestamp, order: .reverse)]); return (try fetch(d)).map { ItemEvent(id: $0.id, itemID: $0.itemID, timestamp: $0.timestamp, type: $0.type, note: $0.note) } }
    func events(in collectionID: UUID) throws -> [ItemEvent] { let id = collectionID; let d = FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == id }, sortBy: [SortDescriptor(\.timestamp)]); return (try fetch(d)).map { ItemEvent(id: $0.id, itemID: $0.itemID, timestamp: $0.timestamp, type: $0.type, note: $0.note) } }
    func role(for collectionID: UUID) throws -> CollectionMemberRole { let id = collectionID; return try fetch(FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == id })).first(where: { !$0.participantID.hasPrefix("share:") })?.role ?? .viewer }
    func pendingMutations() throws -> [SyncMutationRecord] { (try fetch(FetchDescriptor<SyncMutationRecord>(sortBy: [SortDescriptor(\.createdAt)]))) }
    func markMutation(_ mutation: SyncMutationRecord, error: Error? = nil) throws { mutation.attempts += 1; mutation.lastError = error?.localizedDescription; try save() }
    func removeMutation(_ mutation: SyncMutationRecord) throws { context.delete(mutation); try save() }
    func removeMutations(_ mutations: [SyncMutationRecord]) throws { mutations.forEach(context.delete); if !mutations.isEmpty { try save() } }
    func markMutations(_ mutations: [SyncMutationRecord], error: Error) throws { for mutation in mutations { mutation.attempts += 1; mutation.lastError = error.localizedDescription }; if !mutations.isEmpty { try save() } }
    func removeMutations(withIDs ids: Set<UUID>) throws { let records = try pendingMutations().filter { ids.contains($0.id) }; records.forEach(context.delete); if !records.isEmpty { try save() } }
    func markMutations(withIDs ids: Set<UUID>, error: Error) throws { let records = try pendingMutations().filter { ids.contains($0.id) }; for record in records { record.attempts += 1; record.lastError = error.localizedDescription }; if !records.isEmpty { try save() } }
    func setSyncState(collectionID: UUID, state: CollectionSyncState, error: String? = nil, lastSyncedAt: Date? = nil) throws { let id = collectionID; let record: CloudSyncStateRecord; if let existing = try fetch(FetchDescriptor<CloudSyncStateRecord>(predicate: #Predicate { $0.collectionID == id })).first { record = existing } else { record = CloudSyncStateRecord(collectionID: id); context.insert(record) }; record.state = state; record.lastError = error; if let lastSyncedAt { record.lastSyncedAt = lastSyncedAt }; record.pendingCount = try pendingMutations().filter { $0.collectionID == id }.count; try save() }
    func syncState(for collectionID: UUID) throws -> (CollectionSyncState, String?, Int) { let id = collectionID; guard let state = try fetch(FetchDescriptor<CloudSyncStateRecord>(predicate: #Predicate { $0.collectionID == id })).first else { return (.idle, nil, 0) }; return (state.state, state.lastError, state.pendingCount) }
    @discardableResult
    func merge(_ snapshots: [CloudCollectionSnapshot]) throws -> CloudMergeNotificationChanges {
        var notificationChanges = CloudMergeNotificationChanges()
        // A snapshot is fetched from CloudKit, so it still contains everything
        // that has been deleted locally but not pushed yet — either because the
        // sync that fetched it started before the delete, or because the push
        // has not run. Without these tombstones the merge re-inserts every one
        // of those records and the deletion appears to undo itself a second
        // later. The outbox is authoritative until the push clears it.
        let outbox = try pendingMutations()
        let deletedItemIDs = Set(outbox
            .filter { $0.recordType == "CollectionItem" && $0.operation == "delete" }
            .compactMap { $0.itemID ?? UUID(uuidString: $0.recordName) })
        let deletedCollectionIDs = Set(outbox
            .filter { $0.recordType == "Collection" && $0.operation == "delete" }
            .map(\.collectionID))
        var sharedSnapshotsByCollection: [UUID: CloudCollectionSnapshot] = [:]
        for snapshot in snapshots where snapshot.collection.role != .owner {
            sharedSnapshotsByCollection[snapshot.collection.id] = snapshot
        }
        var privateItemsToRecover: [UUID: UUID] = [:]
        for snapshot in snapshots where snapshot.collection.role == .owner {
            guard let sharedSnapshot = sharedSnapshotsByCollection[snapshot.collection.id] else { continue }
            let sharedItems = Dictionary(uniqueKeysWithValues: sharedSnapshot.items.map { ($0.id, $0) })
            for item in snapshot.items {
                if let sharedItem = sharedItems[item.id], item.updatedAt <= sharedItem.updatedAt { continue }
                privateItemsToRecover[item.id] = snapshot.collection.id
            }
        }
        for snapshot in snapshots where !deletedCollectionIDs.contains(snapshot.collection.id) {
            let collectionID = snapshot.collection.id
            let isShadowedPrivateSnapshot = snapshot.collection.role == .owner && sharedSnapshotsByCollection[collectionID] != nil
            let existingCollection = try fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == collectionID })).first
            let canReportSharedItemChanges = existingCollection != nil
            let payload = CollectionSettingsPayload(category: snapshot.collection.category, statuses: snapshot.collection.statuses, mergedTags: snapshot.collection.mergedTags, metadataFields: snapshot.collection.metadataFields, defaultStatusID: snapshot.collection.defaultStatusID, barcodeRequired: snapshot.collection.barcodeRequired)
            let settingsJSON = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "{}"
            if let existingCollection, !isShadowedPrivateSnapshot {
                if existingCollection.name != snapshot.collection.name ||
                    existingCollection.icon != snapshot.collection.icon ||
                    existingCollection.subtitle != snapshot.collection.subtitle ||
                    existingCollection.settingsJSON != settingsJSON {
                    existingCollection.name = snapshot.collection.name
                    existingCollection.icon = snapshot.collection.icon
                    existingCollection.subtitle = snapshot.collection.subtitle
                    existingCollection.settingsJSON = settingsJSON
                    existingCollection.updatedAt = .now
                }
            } else {
                if existingCollection == nil {
                    context.insert(CollectionRecord(id: collectionID, name: snapshot.collection.name, icon: snapshot.collection.icon, subtitle: snapshot.collection.subtitle, settingsJSON: settingsJSON))
                }
            }
            let effectiveRole = sharedSnapshotsByCollection[collectionID]?.collection.role ?? snapshot.collection.role
            let memberships = (try fetch(FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
            if memberships.isEmpty {
                context.insert(CollectionMemberRecord(collectionID: collectionID, participantID: "cloud", role: effectiveRole))
            } else {
                // A failed early share could leave an editor with a private
                // duplicate and an owner membership. Private snapshots are
                // merged first and shared snapshots last, so update every
                // membership here to make the shared role authoritative.
                for membership in memberships {
                    if membership.role != effectiveRole {
                        membership.role = effectiveRole
                        membership.updatedAt = .now
                    }
                }
            }
            if let sharedWith = snapshot.sharedWith {
                let cachedParticipants = memberships.filter { $0.participantID.hasPrefix("share:") }
                let participantIDs = Set(sharedWith.map { "share:" + $0.id })
                for cached in cachedParticipants where !participantIDs.contains(cached.participantID) { context.delete(cached) }
                for participant in sharedWith {
                    let participantID = "share:" + participant.id
                    if let cached = cachedParticipants.first(where: { $0.participantID == participantID }) {
                        if cached.displayName != participant.displayName {
                            cached.displayName = participant.displayName
                            cached.updatedAt = .now
                        }
                    } else {
                        context.insert(CollectionMemberRecord(collectionID: collectionID, participantID: participantID, displayName: participant.displayName, role: effectiveRole))
                    }
                }
            }
            let existingItems = (try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
            var itemsByID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
            for item in snapshot.items where !deletedItemIDs.contains(item.id) {
                if let record = itemsByID[item.id] {
                    if item.updatedAt > record.updatedAt { record.update(from: item) }
                } else {
                    let record = ItemRecord(from: item)
                    context.insert(record)
                    itemsByID[item.id] = record
                    if canReportSharedItemChanges {
                        notificationChanges.sharedItemChanges.append(SharedCollectionItemChange(collectionID: collectionID, collectionName: snapshot.collection.name, itemTitle: item.title, kind: .added))
                    }
                }
            }
            for itemID in snapshot.deletedItemIDs {
                guard let record = itemsByID[itemID] else { continue }
                notificationChanges.sharedItemChanges.append(SharedCollectionItemChange(collectionID: collectionID, collectionName: snapshot.collection.name, itemTitle: record.title, kind: .removed))
                try purgeItemChildren(itemID: itemID)
                context.delete(record)
                itemsByID[itemID] = nil
            }
            // A pending local delete may still have a record here when the
            // snapshot arrived first. Removing it silently keeps the list in
            // step with the outbox without claiming a collaborator did it.
            for itemID in deletedItemIDs {
                guard let record = itemsByID[itemID] else { continue }
                try purgeItemChildren(itemID: itemID)
                context.delete(record)
                itemsByID[itemID] = nil
            }
            let existingRatings = (try fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
            let snapshotRatingKeys = Set(snapshot.ratings.map { "\($0.itemID.uuidString)|\($0.participantID)" })
            for rating in existingRatings where !snapshotRatingKeys.contains("\(rating.itemID.uuidString)|\(rating.participantID)") { context.delete(rating) }
            for rating in snapshot.ratings where !deletedItemIDs.contains(rating.itemID) {
                let existing = existingRatings.first(where: { $0.itemID == rating.itemID && $0.participantID == rating.participantID })
                if let existing {
                    if rating.updatedAt > existing.updatedAt { existing.value = rating.value; existing.participantName = rating.participantName; existing.updatedAt = rating.updatedAt }
                } else { context.insert(ItemRatingRecord(id: rating.id, itemID: rating.itemID, collectionID: collectionID, participantID: rating.participantID, participantName: rating.participantName, value: rating.value, updatedAt: rating.updatedAt)) }
            }
            let existingComments = (try fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
            let snapshotCommentIDs = Set(snapshot.comments.map(\.id))
            for comment in existingComments where !snapshotCommentIDs.contains(comment.id) { context.delete(comment) }
            for comment in snapshot.comments where !deletedItemIDs.contains(comment.itemID) {
                if let existing = existingComments.first(where: { $0.id == comment.id }) {
                    if comment.updatedAt > existing.updatedAt { existing.text = comment.text; existing.participantName = comment.participantName; existing.updatedAt = comment.updatedAt }
                } else { context.insert(ItemCommentRecord(id: comment.id, itemID: comment.itemID, collectionID: collectionID, participantID: comment.participantID, participantName: comment.participantName, text: comment.text, createdAt: comment.createdAt, updatedAt: comment.updatedAt)) }
            }
            let existingEvents = (try fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == collectionID })))
            let existingIDs = Set(existingEvents.map(\.id))
            for event in snapshot.events where !existingIDs.contains(event.id) && !deletedItemIDs.contains(event.itemID) {
                let record = EventRecord(itemID: event.itemID, collectionID: collectionID, type: event.type, note: event.note)
                record.id = event.id; record.timestamp = event.timestamp
                context.insert(record)
            }
        }
        let existingPendingItemSaves = Set(try pendingMutations()
            .filter { $0.recordType == "CollectionItem" && $0.operation != "delete" }
            .map(\.recordName))
        for (itemID, collectionID) in privateItemsToRecover where !existingPendingItemSaves.contains(itemID.uuidString) && !deletedItemIDs.contains(itemID) {
            // Preserve items/edits that the old routing bug successfully saved
            // only to the participant's private duplicate. The next sync now
            // sees an editor role and sends these mutations to the shared zone.
            enqueue(collectionID: collectionID, itemID: itemID, recordName: itemID.uuidString, recordType: "CollectionItem")
        }
        try save(journaling: false)
        return notificationChanges
    }
    private func purgeItemChildren(itemID: UUID) throws {
        let id = itemID
        ((try fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.itemID == id })))).forEach(context.delete)
        ((try fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.itemID == id })))).forEach(context.delete)
        ((try fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.itemID == id })))).forEach(context.delete)
    }
    private func enqueue(collectionID: UUID, itemID: UUID? = nil, recordName: String, recordType: String, operation: String = "save") { context.insert(SyncMutationRecord(collectionID: collectionID, itemID: itemID, recordName: recordName, recordType: recordType, operation: operation)) }
    private func hasCollectionMembership(_ collectionID: UUID) throws -> Bool { let id = collectionID; return ((try fetch(FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == id })))).isEmpty == false }
    private func importSourceIdentity(_ sourceKey: String) -> String { sourceKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private func importIdentity(title: String, brand: String, variant: String) -> String { [title, brand, variant].map(importSourceIdentity).joined(separator: "\u{1f}") }
    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        do {
            try failureInjector?(.fetch)
            return try context.fetch(descriptor)
        } catch {
            context.rollback()
            lastPersistenceError = .fetchFailed
            repositoryLogger.error("SwiftData fetch failed; transaction rolled back")
            throw RepositoryError.fetchFailed
        }
    }

    private func requireItem(_ itemID: UUID, in collectionID: UUID) throws -> ItemRecord {
        guard let record = try fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.id == itemID })).first else { throw RepositoryError.validation("This item is no longer available.") }
        guard record.collectionID == collectionID else { throw RepositoryError.permissionDenied }
        return record
    }

    private func collectionSettings(for collectionID: UUID) throws -> CollectionModel {
        let id = collectionID
        guard let record = try fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == id })).first else { throw RepositoryError.validation("This collection is no longer available.") }
        return model(from: record)
    }

    private func normalizedState(_ state: ItemState, wasExplicit: Bool = true, settings: CollectionModel) -> ItemState {
        if wasExplicit && settings.statuses.contains(where: { $0.id == state.rawValue }) { return state }
        return ItemState(rawValue: settings.defaultStatusID)
    }

    /// V1’s model convenience conversions retain their historical tolerant
    /// encoding behavior. Validate new payloads at the transaction boundary so
    /// nonfinite numbers/dates can never silently replace metadata with `{}`.
    private func validatePayload(metadata: [String: MetadataValue], dates: [Date] = [], sourceSnapshot: ProductSourceSnapshot? = nil) throws {
        do {
            let encoder = JSONEncoder()
            _ = try encoder.encode(metadata)
            _ = try encoder.encode(dates)
            if let sourceSnapshot { _ = try encoder.encode(sourceSnapshot) }
        } catch {
            throw RepositoryError.validation("This item contains a number or date that cannot be saved. Correct its metadata and try again.")
        }
    }

    private func validateCreation(barcode: Barcode?, collectionID: UUID) throws {
        guard !(try collectionSettings(for: collectionID)).barcodeRequired || barcode != nil else { throw RepositoryError.validation("This collection requires a barcode for every item.") }
    }

    private func journalContextChanges() throws {
        // Only deduplicate inside this transaction. An older in-flight mutation
        // must not absorb this edit: acknowledgement removes its generation ID.
        var pending = Set(context.insertedModelsArray.compactMap { $0 as? SyncMutationRecord }.map { "\($0.recordType)|\($0.recordName)|\($0.operation == "createCollection" ? "save" : $0.operation)" })
        func stage(_ model: any PersistentModel, operation: String) {
            let identity: (UUID, UUID?, String, String)
            switch model {
            case let value as CollectionRecord: identity = (value.id, nil, value.id.uuidString, "Collection")
            case let value as ItemRecord: identity = (value.collectionID, value.id, value.id.uuidString, "CollectionItem")
            case let value as EventRecord: identity = (value.collectionID, value.itemID, value.id.uuidString, "CollectionEvent")
            case let value as ItemRatingRecord: identity = (value.collectionID, value.itemID, CollaborationRecordNames.rating(itemID: value.itemID, participantID: value.participantID), "CollectionItemRating")
            case let value as ItemCommentRecord: identity = (value.collectionID, value.itemID, CollaborationRecordNames.comment(value.id), "CollectionItemComment")
            default: return
            }
            let key = "\(identity.3)|\(identity.2)|\(operation)"
            if pending.insert(key).inserted { enqueue(collectionID: identity.0, itemID: identity.1, recordName: identity.2, recordType: identity.3, operation: operation) }
        }
        for model in context.insertedModelsArray + context.changedModelsArray { stage(model, operation: "save") }
        for model in context.deletedModelsArray { stage(model, operation: "delete") }
    }

    @discardableResult
    private func save(journaling: Bool = true) throws -> Bool {
        do {
            if journaling { try journalContextChanges() }
            let hasNewOutgoingIntent = context.insertedModelsArray.contains { $0 is SyncMutationRecord }
            try failureInjector?(.save)
            try context.save()
            if journaling && hasNewOutgoingIntent { NotificationCenter.default.post(name: .collectionManagerLocalChanges, object: nil) }
            lastPersistenceError = nil
            return true
        } catch {
            // Roll back the failed transaction so callers never observe a
            // success-looking in-memory mutation after persistence failed.
            context.rollback()
            lastPersistenceError = .saveFailed
            repositoryLogger.error("SwiftData save failed; transaction rolled back: \(String(describing: type(of: error)), privacy: .public)")
            throw RepositoryError.saveFailed
        }
    }
}
