import Foundation
import SwiftData

@MainActor final class CollectionRepository {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }
    func collections() -> [CollectionModel] {
        let records = (try? context.fetch(FetchDescriptor<CollectionRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        let members = (try? context.fetch(FetchDescriptor<CollectionMemberRecord>())) ?? []
        var roles: [UUID: CollectionMemberRole] = [:]
        for member in members where roles[member.collectionID] == nil { roles[member.collectionID] = member.role }
        return records.map { model(from: $0, role: roles[$0.id] ?? .owner) }
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
        return CollectionModel(id: record.id, name: record.name, icon: record.icon, subtitle: record.subtitle, category: payload.category, statuses: payload.statuses, mergedTags: payload.mergedTags, role: role)
    }
    private func mergedTags(for collectionID: UUID) -> [MergedTagRule] {
        let id = collectionID
        guard let record = try? context.fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == id })).first else { return [] }
        return (try? JSONDecoder().decode(CollectionSettingsPayload.self, from: Data(record.settingsJSON.utf8)))?.mergedTags ?? []
    }
    func items(in collectionID: UUID) -> [CollectionItem] {
        let descriptor = FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let records = (try? context.fetch(descriptor)) ?? []
        let ratingRecords = (try? context.fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let commentRecords = (try? context.fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == collectionID }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let ratingsByItem = Dictionary(grouping: ratingRecords.map(\.domain), by: \.itemID)
        let commentsByItem = Dictionary(grouping: commentRecords.map(\.domain), by: \.itemID)
        var migrated = false
        for record in records {
            let item = record.domain
            let encoded = (try? String(data: JSONEncoder().encode(TagUtilities.dateTags(from: item.tags)), encoding: .utf8)) ?? "{}"
            if record.dateTagsJSON != encoded {
                record.dateTagsJSON = encoded
                migrated = true
            }
        }
        if migrated { save() }
        return records.map { record in
            var item = record.domain
            item.ratings = ratingsByItem[item.id, default: []].sorted { $0.participantName.localizedStandardCompare($1.participantName) == .orderedAscending }
            item.comments = commentsByItem[item.id, default: []]
            return item
        }
    }
    func addCollection(name: String, icon: String, subtitle: String, category: CollectionCategory = .custom) { let record = CollectionRecord(name: name, icon: icon, subtitle: subtitle, settingsJSON: (try? String(data: JSONEncoder().encode(CollectionSettingsPayload(category: category)), encoding: .utf8)) ?? "{}"); context.insert(record); context.insert(CollectionMemberRecord(collectionID: record.id, participantID: "local", role: .owner)); enqueue(collectionID: record.id, recordName: record.id.uuidString, recordType: "Collection"); save() }
    func deleteCollection(_ collection: CollectionModel) {
        guard collection.role.canDelete else { return }
        let collectionID = collection.id
        guard let record = try? context.fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == collectionID })).first else { return }
        let items = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let ratings = (try? context.fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let comments = (try? context.fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let events = (try? context.fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let webSyncs = (try? context.fetch(FetchDescriptor<WebSyncRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let members = (try? context.fetch(FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let mutations = (try? context.fetch(FetchDescriptor<SyncMutationRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let syncStates = (try? context.fetch(FetchDescriptor<CloudSyncStateRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        items.forEach(context.delete); ratings.forEach(context.delete); comments.forEach(context.delete); events.forEach(context.delete); webSyncs.forEach(context.delete); members.forEach(context.delete); mutations.forEach(context.delete); syncStates.forEach(context.delete)
        enqueue(collectionID: collectionID, recordName: collectionID.uuidString, recordType: "Collection", operation: "delete")
        context.delete(record)
        save()
    }
    func updateCollection(_ collection: CollectionModel) {
        guard collection.role.canEdit else { return }
        let collectionID = collection.id
        guard let record = try? context.fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == collectionID })).first else { return }
        record.name = collection.name; record.icon = collection.icon; record.subtitle = collection.subtitle; record.updatedAt = .now
        let statuses = collection.statuses.isEmpty ? CollectionStatus.defaults : collection.statuses
        let payload = CollectionSettingsPayload(category: collection.category, statuses: statuses, mergedTags: collection.mergedTags)
        record.settingsJSON = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "{}"

        // Items keep the status ID, so removing a status must not leave items
        // pointing at a status that can no longer be selected or displayed.
        let validStatusIDs = Set(statuses.map(\.id))
        if let records = try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID })), let fallback = statuses.first?.id {
            for item in records where !validStatusIDs.contains(item.stateRawValue) {
                item.stateRawValue = fallback
                item.updatedAt = .now
            }
        }
        enqueue(collectionID: collection.id, recordName: collection.id.uuidString, recordType: "Collection")
        save()
    }
    func addItem(_ item: CollectionItem) { guard role(for: item.collectionID).canEdit else { return }; var item = item; item.tags = TagUtilities.applyingMergedTags(item.tags, rules: mergedTags(for: item.collectionID)); context.insert(ItemRecord(from: item)); context.insert(EventRecord(itemID: item.id, collectionID: item.collectionID, type: "created")); enqueue(collectionID: item.collectionID, recordName: item.id.uuidString, recordType: "CollectionItem"); save() }
    func webSyncs(for collectionID: UUID) -> [WebSyncRecord] { (try? context.fetch(FetchDescriptor<WebSyncRecord>(predicate: #Predicate { $0.collectionID == collectionID }, sortBy: [SortDescriptor(\.urlString)]))) ?? [] }
    func addWebSync(_ sync: WebSyncRecord) { context.insert(sync); save() }
    func updateWebSync(_ sync: WebSyncRecord) { save() }
    func deleteWebSync(_ sync: WebSyncRecord) { context.delete(sync); save() }
    func setWebSync(_ sync: WebSyncRecord, lastSyncAt: Date?, error: String?) { sync.lastSyncAt = lastSyncAt; sync.lastError = error; save() }
    func hasImportedItem(collectionID: UUID, sourceKey: String) -> Bool { let count = try? context.fetchCount(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID && $0.importSourceKey == sourceKey })); return (count ?? 0) > 0 }
    func importedSourceKeys(in collectionID: UUID) -> Set<String> {
        let records = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        return Set(records.compactMap(\.importSourceKey))
    }
    func importDraft(_ draft: ImportDraft, collectionID: UUID, sourceKey: String) -> Bool {
        let records = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let brand = draft.brand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let variant = draft.variant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existing = records.first(where: { $0.importSourceKey == sourceKey }) ?? records.first(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title &&
            $0.brand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == brand &&
            $0.variant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == variant
        })
        if let existing {
            let previous = existing.domain
            var item = previous
            item.title = draft.title; item.brand = draft.brand; item.variant = draft.variant; item.itemDescription = draft.description; item.state = draft.state; item.quantity = draft.quantity; item.tags = TagUtilities.applyingMergedTags(draft.tags, rules: mergedTags(for: collectionID)); item.barcode = draft.barcode ?? item.barcode; item.importSourceKey = sourceKey; item.updatedAt = .now
            existing.update(from: item)
            context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: previous.state == item.state ? "imported" : "importedStateChanged")); save()
            return false
        }
        let item = CollectionItem(id: UUID(), collectionID: collectionID, title: draft.title, brand: draft.brand, variant: draft.variant, itemDescription: draft.description, state: draft.state, quantity: draft.quantity, barcode: draft.barcode, createdAt: .now, updatedAt: .now, consumedAt: draft.state == .consumed ? .now : nil, tags: TagUtilities.applyingMergedTags(draft.tags, rules: mergedTags(for: collectionID)), metadata: [:], imageSystemName: "shippingbox.fill", imageData: nil, importSourceKey: sourceKey)
        addItem(item); context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "imported")); save(); return true
    }
    func importDrafts(_ drafts: [(draft: ImportDraft, sourceKey: String)], collectionID: UUID) {
        guard role(for: collectionID).canEdit, !drafts.isEmpty else { return }
        let records = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let rules = mergedTags(for: collectionID)
        var bySource: [String: ItemRecord] = [:]
        for record in records where bySource[record.importSourceKey ?? ""] == nil {
            if let sourceKey = record.importSourceKey { bySource[sourceKey] = record }
        }
        var byIdentity: [String: ItemRecord] = [:]
        for record in records { byIdentity[importIdentity(title: record.title, brand: record.brand, variant: record.variant)] = record }

        for entry in drafts {
            let draft = entry.draft
            let existing = bySource[entry.sourceKey] ?? byIdentity[importIdentity(title: draft.title, brand: draft.brand, variant: draft.variant)]
            if let existing {
                let previous = existing.domain
                var item = previous
                item.title = draft.title; item.brand = draft.brand; item.variant = draft.variant; item.itemDescription = draft.description; item.state = draft.state; item.quantity = draft.quantity; item.tags = TagUtilities.applyingMergedTags(draft.tags, rules: rules); item.barcode = draft.barcode ?? item.barcode; item.importSourceKey = entry.sourceKey; item.updatedAt = .now
                existing.update(from: item)
                context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: previous.state == item.state ? "imported" : "importedStateChanged"))
                bySource[entry.sourceKey] = existing
                byIdentity[importIdentity(title: item.title, brand: item.brand, variant: item.variant)] = existing
            } else {
                let item = CollectionItem(id: UUID(), collectionID: collectionID, title: draft.title, brand: draft.brand, variant: draft.variant, itemDescription: draft.description, state: draft.state, quantity: draft.quantity, barcode: draft.barcode, createdAt: .now, updatedAt: .now, consumedAt: draft.state == .consumed ? .now : nil, tags: TagUtilities.applyingMergedTags(draft.tags, rules: rules), metadata: [:], imageSystemName: "shippingbox.fill", imageData: nil, importSourceKey: entry.sourceKey)
                let record = ItemRecord(from: item)
                context.insert(record); context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "created")); context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "imported")); enqueue(collectionID: collectionID, recordName: item.id.uuidString, recordType: "CollectionItem")
                bySource[entry.sourceKey] = record
                byIdentity[importIdentity(title: item.title, brand: item.brand, variant: item.variant)] = record
            }
        }
        save()
    }
    func deduplicateItems(in collectionID: UUID) -> Int {
        let records = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        var seen = Set<String>(); var removed = 0
        for record in records {
            let source = record.importSourceKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard source?.isEmpty == false else { continue }
            let key = "source:\(source!)"
            if seen.insert(key).inserted { continue }; context.delete(record); enqueue(collectionID: collectionID, recordName: record.id.uuidString, recordType: "CollectionItem", operation: "delete"); removed += 1
        }
        if removed > 0 { save() }; return removed
    }
    func deleteAllImportedItems(in collectionID: UUID) -> Int {
        let records = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let imported = records.filter { !($0.importSourceKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        for record in imported { context.delete(record); enqueue(collectionID: collectionID, recordName: record.id.uuidString, recordType: "CollectionItem", operation: "delete") }
        if !imported.isEmpty { save() }; return imported.count
    }
    func applyTagRules(_ options: TagGenerationOptions, in collectionID: UUID) -> Int {
        let records = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        var changed = 0
        for record in records {
            let item = record.domain
            let rawTags = options.keepExistingTags ? item.tags.joined(separator: options.separators.first.map(String.init) ?? ",") : ""
            let tags = TagUtilities.applyingMergedTags(TagUtilities.tags(title: item.title, existing: item.tags, rawTags: rawTags, options: options), rules: mergedTags(for: collectionID))
            guard tags != item.tags else { continue }
            var updated = item; updated.tags = tags; updated.updatedAt = .now
            record.update(from: updated); changed += 1
        }
        if changed > 0 { save() }
        return changed
    }
    func applyMergedTags(in collectionID: UUID) -> Int {
        let records = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let rules = mergedTags(for: collectionID)
        var changed = 0
        for record in records {
            let item = record.domain
            let tags = TagUtilities.applyingMergedTags(item.tags, rules: rules)
            guard tags != item.tags else { continue }
            var updated = item; updated.tags = tags; updated.updatedAt = .now
            record.update(from: updated); changed += 1
        }
        if changed > 0 { save() }
        return changed
    }
    func applyWebDraft(_ draft: ImportDraft, collectionID: UUID, sourceKey: String, updateExistingState: Bool) -> Bool { let existing = try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID && $0.importSourceKey == sourceKey })).first; if let existing { let previous = existing.domain; var item = previous; item.title = draft.title; item.brand = draft.brand; item.variant = draft.variant; item.itemDescription = draft.description; item.quantity = draft.quantity; item.tags = TagUtilities.applyingMergedTags(draft.tags, rules: mergedTags(for: collectionID)); item.barcode = draft.barcode ?? item.barcode; if updateExistingState { item.state = draft.state; item.consumedAt = draft.state == .consumed ? (item.consumedAt ?? .now) : nil }; item.updatedAt = .now; existing.update(from: item); context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: updateExistingState && previous.state != item.state ? "importedStateChanged" : "imported")); save(); return false }; let item = CollectionItem(id: UUID(), collectionID: collectionID, title: draft.title, brand: draft.brand, variant: draft.variant, itemDescription: draft.description, state: draft.state, quantity: draft.quantity, barcode: draft.barcode, createdAt: .now, updatedAt: .now, consumedAt: draft.state == .consumed ? .now : nil, tags: TagUtilities.applyingMergedTags(draft.tags, rules: mergedTags(for: collectionID)), metadata: [:], imageSystemName: "shippingbox.fill", imageData: nil, importSourceKey: sourceKey); addItem(item); context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "imported")); save(); return true }
    func applyWebDrafts(_ drafts: [(draft: ImportDraft, sourceKey: String, updateExistingState: Bool)], collectionID: UUID) -> (added: Int, updated: Int) {
        guard role(for: collectionID).canEdit, !drafts.isEmpty else { return (0, 0) }
        let records = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let rules = mergedTags(for: collectionID)
        var bySource: [String: ItemRecord] = [:]
        for record in records where bySource[record.importSourceKey ?? ""] == nil {
            if let sourceKey = record.importSourceKey { bySource[sourceKey] = record }
        }
        var added = 0
        var updated = 0

        for entry in drafts {
            let draft = entry.draft
            if let existing = bySource[entry.sourceKey] {
                let previous = existing.domain
                var item = previous
                item.title = draft.title; item.brand = draft.brand; item.variant = draft.variant; item.itemDescription = draft.description; item.quantity = draft.quantity; item.tags = TagUtilities.applyingMergedTags(draft.tags, rules: rules); item.barcode = draft.barcode ?? item.barcode; item.importSourceKey = entry.sourceKey
                if entry.updateExistingState { item.state = draft.state; item.consumedAt = draft.state == .consumed ? (item.consumedAt ?? .now) : nil }
                item.updatedAt = .now
                existing.update(from: item)
                context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: entry.updateExistingState && previous.state != item.state ? "importedStateChanged" : "imported"))
                updated += 1
            } else {
                let item = CollectionItem(id: UUID(), collectionID: collectionID, title: draft.title, brand: draft.brand, variant: draft.variant, itemDescription: draft.description, state: draft.state, quantity: draft.quantity, barcode: draft.barcode, createdAt: .now, updatedAt: .now, consumedAt: draft.state == .consumed ? .now : nil, tags: TagUtilities.applyingMergedTags(draft.tags, rules: rules), metadata: [:], imageSystemName: "shippingbox.fill", imageData: nil, importSourceKey: entry.sourceKey)
                let record = ItemRecord(from: item)
                context.insert(record); context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "created")); context.insert(EventRecord(itemID: item.id, collectionID: collectionID, type: "imported")); enqueue(collectionID: collectionID, recordName: item.id.uuidString, recordType: "CollectionItem")
                bySource[entry.sourceKey] = record
                added += 1
            }
        }
        save()
        return (added, updated)
    }
    func updateItem(_ item: CollectionItem, previousState: ItemState? = nil) { guard role(for: item.collectionID).canEdit else { return }; let itemID = item.id; guard let record = try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.id == itemID })).first else { return }; var item = item; item.tags = TagUtilities.applyingMergedTags(item.tags, rules: mergedTags(for: item.collectionID)); record.update(from: item); if let previousState, previousState != item.state { context.insert(EventRecord(itemID: item.id, collectionID: item.collectionID, type: "stateChanged", note: "\(previousState.label) → \(item.state.label)")) }; enqueue(collectionID: item.collectionID, recordName: item.id.uuidString, recordType: "CollectionItem"); save() }
    func setRating(for item: CollectionItem, value: Int?, participant: CollaboratorIdentity) {
        guard role(for: item.collectionID) != .viewer || hasCollectionMembership(item.collectionID) else { return }
        let itemID = item.id; let participantID = participant.id
        let existing = try? context.fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.itemID == itemID && $0.participantID == participantID })).first
        let recordName = CollaborationRecordNames.rating(itemID: item.id, participantID: participant.id)
        if let value, (1...5).contains(value) {
            if let existing { existing.value = value; existing.participantName = participant.displayName; existing.updatedAt = .now }
            else { context.insert(ItemRatingRecord(itemID: item.id, collectionID: item.collectionID, participantID: participant.id, participantName: participant.displayName, value: value)) }
            enqueue(collectionID: item.collectionID, itemID: item.id, recordName: recordName, recordType: "CollectionItemRating")
        } else if let existing {
            context.delete(existing)
            enqueue(collectionID: item.collectionID, itemID: item.id, recordName: recordName, recordType: "CollectionItemRating", operation: "delete")
        }
        save()
    }
    @discardableResult func addComment(to item: CollectionItem, text: String, participant: CollaboratorIdentity) -> ItemComment? {
        guard role(for: item.collectionID) != .viewer || hasCollectionMembership(item.collectionID) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let record = ItemCommentRecord(itemID: item.id, collectionID: item.collectionID, participantID: participant.id, participantName: participant.displayName, text: trimmed)
        context.insert(record)
        enqueue(collectionID: item.collectionID, itemID: item.id, recordName: CollaborationRecordNames.comment(record.id), recordType: "CollectionItemComment")
        save()
        return record.domain
    }
    func deleteItem(_ item: CollectionItem) { guard role(for: item.collectionID).canEdit, item.state != .consumed else { return }; let itemID = item.id; guard let record = try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.id == itemID })).first else { return }; let ratings = (try? context.fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.itemID == itemID }))) ?? []; let comments = (try? context.fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.itemID == itemID }))) ?? []; ratings.forEach { context.delete($0); enqueue(collectionID: item.collectionID, itemID: item.id, recordName: CollaborationRecordNames.rating(itemID: item.id, participantID: $0.participantID), recordType: "CollectionItemRating", operation: "delete") }; comments.forEach { context.delete($0); enqueue(collectionID: item.collectionID, itemID: item.id, recordName: CollaborationRecordNames.comment($0.id), recordType: "CollectionItemComment", operation: "delete") }; context.delete(record); enqueue(collectionID: item.collectionID, recordName: item.id.uuidString, recordType: "CollectionItem", operation: "delete"); save() }
    func deleteAllItems(in collectionID: UUID) -> Int {
        let items = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let events = (try? context.fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let ratings = (try? context.fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        let comments = (try? context.fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
        for item in items { context.delete(item); enqueue(collectionID: collectionID, recordName: item.id.uuidString, recordType: "CollectionItem", operation: "delete") }
        for rating in ratings { context.delete(rating); enqueue(collectionID: collectionID, itemID: rating.itemID, recordName: CollaborationRecordNames.rating(itemID: rating.itemID, participantID: rating.participantID), recordType: "CollectionItemRating", operation: "delete") }
        for comment in comments { context.delete(comment); enqueue(collectionID: collectionID, itemID: comment.itemID, recordName: CollaborationRecordNames.comment(comment.id), recordType: "CollectionItemComment", operation: "delete") }
        events.forEach(context.delete)
        if !items.isEmpty || !events.isEmpty { save() }
        return items.count
    }
    func events(for item: CollectionItem) -> [ItemEvent] { let itemID = item.id; let d = FetchDescriptor<EventRecord>(predicate: #Predicate { $0.itemID == itemID }, sortBy: [SortDescriptor(\.timestamp, order: .reverse)]); return (try? context.fetch(d))?.map { ItemEvent(id: $0.id, itemID: $0.itemID, timestamp: $0.timestamp, type: $0.type, note: $0.note) } ?? [] }
    func events(in collectionID: UUID) -> [ItemEvent] { let id = collectionID; let d = FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == id }, sortBy: [SortDescriptor(\.timestamp)]); return (try? context.fetch(d))?.map { ItemEvent(id: $0.id, itemID: $0.itemID, timestamp: $0.timestamp, type: $0.type, note: $0.note) } ?? [] }
    func role(for collectionID: UUID) -> CollectionMemberRole { let id = collectionID; return (try? context.fetch(FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == id })).first?.role) ?? .owner }
    func pendingMutations() -> [SyncMutationRecord] { (try? context.fetch(FetchDescriptor<SyncMutationRecord>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [] }
    func markMutation(_ mutation: SyncMutationRecord, error: Error? = nil) { mutation.attempts += 1; mutation.lastError = error?.localizedDescription; save() }
    func removeMutation(_ mutation: SyncMutationRecord) { context.delete(mutation); save() }
    func setSyncState(collectionID: UUID, state: CollectionSyncState, error: String? = nil, lastSyncedAt: Date? = nil) { let id = collectionID; let record: CloudSyncStateRecord; if let existing = try? context.fetch(FetchDescriptor<CloudSyncStateRecord>(predicate: #Predicate { $0.collectionID == id })).first { record = existing } else { record = CloudSyncStateRecord(collectionID: id); context.insert(record) }; record.state = state; record.lastError = error; if let lastSyncedAt { record.lastSyncedAt = lastSyncedAt }; record.pendingCount = pendingMutations().filter { $0.collectionID == id }.count; save() }
    func syncState(for collectionID: UUID) -> (CollectionSyncState, String?, Int) { let id = collectionID; guard let state = try? context.fetch(FetchDescriptor<CloudSyncStateRecord>(predicate: #Predicate { $0.collectionID == id })).first else { return (.idle, nil, 0) }; return (state.state, state.lastError, state.pendingCount) }
    func merge(_ snapshots: [CloudCollectionSnapshot]) {
        for snapshot in snapshots {
            let collectionID = snapshot.collection.id
            let existingCollection = try? context.fetch(FetchDescriptor<CollectionRecord>(predicate: #Predicate { $0.id == collectionID })).first
            if let existingCollection {
                existingCollection.name = snapshot.collection.name; existingCollection.icon = snapshot.collection.icon; existingCollection.subtitle = snapshot.collection.subtitle; existingCollection.updatedAt = .now
                let payload = CollectionSettingsPayload(category: snapshot.collection.category, statuses: snapshot.collection.statuses, mergedTags: snapshot.collection.mergedTags)
                existingCollection.settingsJSON = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? existingCollection.settingsJSON
            } else {
                let payload = CollectionSettingsPayload(category: snapshot.collection.category, statuses: snapshot.collection.statuses, mergedTags: snapshot.collection.mergedTags)
                let settingsJSON = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "{}"
                context.insert(CollectionRecord(id: collectionID, name: snapshot.collection.name, icon: snapshot.collection.icon, subtitle: snapshot.collection.subtitle, settingsJSON: settingsJSON)); context.insert(CollectionMemberRecord(collectionID: collectionID, participantID: "cloud", role: snapshot.collection.role))
            }
            let existingItems = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
            var itemsByID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
            for item in snapshot.items {
                if let record = itemsByID[item.id] {
                    if item.updatedAt >= record.updatedAt { record.update(from: item) }
                } else { let record = ItemRecord(from: item); context.insert(record); itemsByID[item.id] = record }
            }
            let existingRatings = (try? context.fetch(FetchDescriptor<ItemRatingRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
            let snapshotRatingKeys = Set(snapshot.ratings.map { "\($0.itemID.uuidString)|\($0.participantID)" })
            for rating in existingRatings where !snapshotRatingKeys.contains("\(rating.itemID.uuidString)|\(rating.participantID)") { context.delete(rating) }
            for rating in snapshot.ratings {
                let existing = existingRatings.first(where: { $0.itemID == rating.itemID && $0.participantID == rating.participantID })
                if let existing {
                    if rating.updatedAt >= existing.updatedAt { existing.value = rating.value; existing.participantName = rating.participantName; existing.updatedAt = rating.updatedAt }
                } else { context.insert(ItemRatingRecord(id: rating.id, itemID: rating.itemID, collectionID: collectionID, participantID: rating.participantID, participantName: rating.participantName, value: rating.value, updatedAt: rating.updatedAt)) }
            }
            let existingComments = (try? context.fetch(FetchDescriptor<ItemCommentRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
            let snapshotCommentIDs = Set(snapshot.comments.map(\.id))
            for comment in existingComments where !snapshotCommentIDs.contains(comment.id) { context.delete(comment) }
            for comment in snapshot.comments {
                if let existing = existingComments.first(where: { $0.id == comment.id }) {
                    if comment.updatedAt >= existing.updatedAt { existing.text = comment.text; existing.participantName = comment.participantName; existing.updatedAt = comment.updatedAt }
                } else { context.insert(ItemCommentRecord(id: comment.id, itemID: comment.itemID, collectionID: collectionID, participantID: comment.participantID, participantName: comment.participantName, text: comment.text, createdAt: comment.createdAt, updatedAt: comment.updatedAt)) }
            }
            let existingEvents = (try? context.fetch(FetchDescriptor<EventRecord>(predicate: #Predicate { $0.collectionID == collectionID }))) ?? []
            let existingIDs = Set(existingEvents.map(\.id))
            for event in snapshot.events where !existingIDs.contains(event.id) {
                let record = EventRecord(itemID: event.itemID, collectionID: collectionID, type: event.type, note: event.note)
                record.id = event.id; record.timestamp = event.timestamp
                context.insert(record)
            }
        }
        save()
    }
    private func enqueue(collectionID: UUID, itemID: UUID? = nil, recordName: String, recordType: String, operation: String = "save") { context.insert(SyncMutationRecord(collectionID: collectionID, itemID: itemID, recordName: recordName, recordType: recordType, operation: operation)) }
    private func hasCollectionMembership(_ collectionID: UUID) -> Bool { let id = collectionID; return ((try? context.fetch(FetchDescriptor<CollectionMemberRecord>(predicate: #Predicate { $0.collectionID == id }))) ?? []).isEmpty == false }
    private func importIdentity(title: String, brand: String, variant: String) -> String { [title, brand, variant].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.joined(separator: "\u{1f}") }
    private func save() { try? context.save() }
}
