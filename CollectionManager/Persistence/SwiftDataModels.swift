import Foundation
import SwiftData

@Model final class CollectionRecord {
    var id: UUID = UUID(); var name: String = ""; var icon: String = "square.stack.3d.up.fill"; var subtitle: String = "Private"; var createdAt: Date = Date(); var updatedAt: Date = Date(); var settingsJSON: String = "{}"
    init(id: UUID = UUID(), name: String, icon: String = "square.stack.3d.up.fill", subtitle: String = "Private", createdAt: Date = .now, updatedAt: Date = .now, settingsJSON: String = "{}") { self.id = id; self.name = name; self.icon = icon; self.subtitle = subtitle; self.createdAt = createdAt; self.updatedAt = updatedAt; self.settingsJSON = settingsJSON }
}

@Model final class CollectionMemberRecord {
    var id: UUID = UUID(); var collectionID: UUID = UUID(); var participantID: String = ""; var displayName: String = ""; var roleRawValue: String = "editor"; var updatedAt: Date = Date()
    init(collectionID: UUID, participantID: String, displayName: String = "", role: CollectionMemberRole) { self.collectionID = collectionID; self.participantID = participantID; self.displayName = displayName; self.roleRawValue = role.rawValue }
    var role: CollectionMemberRole { get { CollectionMemberRole(rawValue: roleRawValue) ?? .viewer } set { roleRawValue = newValue.rawValue } }
}

@Model final class SyncMutationRecord {
    var id: UUID = UUID(); var collectionID: UUID = UUID(); var itemID: UUID?; var recordName: String = ""; var recordType: String = ""; var operation: String = "save"; var createdAt: Date = Date(); var attempts: Int = 0; var lastError: String?
    init(collectionID: UUID, itemID: UUID? = nil, recordName: String, recordType: String, operation: String = "save") { self.collectionID = collectionID; self.itemID = itemID; self.recordName = recordName; self.recordType = recordType; self.operation = operation }
}

@Model final class CloudSyncStateRecord {
    var id: UUID = UUID(); var collectionID: UUID = UUID(); var stateRawValue: String = "idle"; var lastSyncedAt: Date?; var lastError: String?; var pendingCount: Int = 0
    init(collectionID: UUID) { self.collectionID = collectionID }
    var state: CollectionSyncState { get { CollectionSyncState(rawValue: stateRawValue) ?? .idle } set { stateRawValue = newValue.rawValue } }
}

@Model final class ItemRecord {
    var id: UUID = UUID(); var collectionID: UUID = UUID(); var title: String = ""; var brand: String = ""; var variant: String = ""; var itemDescription: String = ""; var stateRawValue: String = "wanted"; var quantity: Int = 1; var barcodeValue: String?; var barcodeType: String?; var createdAt: Date = Date(); var updatedAt: Date = Date(); var consumedAt: Date?; var tagsJSON: String = "[]"; var dateTagsJSON: String = "{}"; var metadataJSON: String = "{}"; var imageSystemName: String = "shippingbox.fill"; var imageData: Data?; var importSourceKey: String?
    init(from item: CollectionItem) { id = item.id; collectionID = item.collectionID; title = item.title; brand = item.brand; variant = item.variant; itemDescription = item.itemDescription; stateRawValue = item.state.rawValue; quantity = item.quantity; barcodeValue = item.barcode?.value; barcodeType = item.barcode?.type; createdAt = item.createdAt; updatedAt = item.updatedAt; consumedAt = item.consumedAt; tagsJSON = (try? String(data: JSONEncoder().encode(item.tags), encoding: .utf8)) ?? "[]"; dateTagsJSON = (try? String(data: JSONEncoder().encode(TagUtilities.dateTags(from: item.tags)), encoding: .utf8)) ?? "{}"; metadataJSON = (try? String(data: JSONEncoder().encode(item.metadata), encoding: .utf8)) ?? "{}"; imageSystemName = item.imageSystemName; imageData = item.imageData; importSourceKey = item.importSourceKey }
    func update(from item: CollectionItem) { title = item.title; brand = item.brand; variant = item.variant; itemDescription = item.itemDescription; stateRawValue = item.state.rawValue; quantity = item.quantity; barcodeValue = item.barcode?.value; barcodeType = item.barcode?.type; updatedAt = item.updatedAt; consumedAt = item.consumedAt; tagsJSON = (try? String(data: JSONEncoder().encode(item.tags), encoding: .utf8)) ?? "[]"; dateTagsJSON = (try? String(data: JSONEncoder().encode(TagUtilities.dateTags(from: item.tags)), encoding: .utf8)) ?? "{}"; metadataJSON = (try? String(data: JSONEncoder().encode(item.metadata), encoding: .utf8)) ?? "{}"; imageSystemName = item.imageSystemName; imageData = item.imageData; importSourceKey = item.importSourceKey }
    var domain: CollectionItem { let tags = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []; let storedDates = (try? JSONDecoder().decode([String: Date].self, from: Data(dateTagsJSON.utf8))) ?? [:]; return CollectionItem(id: id, collectionID: collectionID, title: title, brand: brand, variant: variant, itemDescription: itemDescription, state: ItemState(rawValue: stateRawValue), quantity: quantity, barcode: barcodeValue.flatMap { Barcode(rawValue: $0, type: barcodeType ?? "EAN-13") }, createdAt: createdAt, updatedAt: updatedAt, consumedAt: consumedAt, tags: tags, metadata: (try? JSONDecoder().decode([String: MetadataValue].self, from: Data(metadataJSON.utf8))) ?? [:], imageSystemName: imageSystemName, imageData: imageData, importSourceKey: importSourceKey, dateTags: storedDates.isEmpty ? TagUtilities.dateTags(from: tags) : storedDates) }
}

@Model final class ItemRatingRecord {
    var id: UUID = UUID(); var itemID: UUID = UUID(); var collectionID: UUID = UUID(); var participantID: String = ""; var participantName: String = ""; var value: Int = 0; var updatedAt: Date = Date()
    init(id: UUID = UUID(), itemID: UUID, collectionID: UUID, participantID: String, participantName: String, value: Int, updatedAt: Date = .now) { self.id = id; self.itemID = itemID; self.collectionID = collectionID; self.participantID = participantID; self.participantName = participantName; self.value = value; self.updatedAt = updatedAt }
    var domain: ItemRating { ItemRating(id: id, itemID: itemID, participantID: participantID, participantName: participantName, value: value, updatedAt: updatedAt) }
}

@Model final class ItemCommentRecord {
    var id: UUID = UUID(); var itemID: UUID = UUID(); var collectionID: UUID = UUID(); var participantID: String = ""; var participantName: String = ""; var text: String = ""; var createdAt: Date = Date(); var updatedAt: Date = Date()
    init(id: UUID = UUID(), itemID: UUID, collectionID: UUID, participantID: String, participantName: String, text: String, createdAt: Date = .now, updatedAt: Date = .now) { self.id = id; self.itemID = itemID; self.collectionID = collectionID; self.participantID = participantID; self.participantName = participantName; self.text = text; self.createdAt = createdAt; self.updatedAt = updatedAt }
    var domain: ItemComment { ItemComment(id: id, itemID: itemID, participantID: participantID, participantName: participantName, text: text, createdAt: createdAt, updatedAt: updatedAt) }
}

@Model final class WebSyncRecord {
    var id: UUID = UUID(); var collectionID: UUID = UUID(); var urlString: String = ""; var tableName: String = ""; var headersJSON: String = "[]"; var mappingJSON: String = "[]"; var tagSeparators: String = ",|;/"; var splitTagsOnWhitespace: Bool = false; var generateTagsFromTitle: Bool = false; var titleTagModeRawValue: String = TitleTagMode.firstSegment.rawValue; var titleSeparators: String = "-–—_:|/,"; var intervalMinutes: Int = 360; var enabled: Bool = true; var addNewItems: Bool = true; var updateExistingStates: Bool = true; var fixedStateRawValue: String?; var lastSyncAt: Date?; var lastError: String?
    init(collectionID: UUID, urlString: String, tableName: String, headers: [String], mapping: [HTMLImportField], intervalMinutes: Int = 360, addNewItems: Bool = true, updateExistingStates: Bool = true, fixedState: ItemState? = nil, tagOptions: TagGenerationOptions = TagGenerationOptions()) { id = UUID(); self.collectionID = collectionID; self.urlString = urlString; self.tableName = tableName; headersJSON = (try? String(data: JSONEncoder().encode(headers), encoding: .utf8)) ?? "[]"; mappingJSON = (try? String(data: JSONEncoder().encode(mapping.map(\.rawValue)), encoding: .utf8)) ?? "[]"; self.tagSeparators = tagOptions.separators; self.splitTagsOnWhitespace = tagOptions.splitOnWhitespace; self.generateTagsFromTitle = tagOptions.generateFromTitle; self.titleTagModeRawValue = tagOptions.titleMode.rawValue; self.titleSeparators = tagOptions.titleSeparators; self.intervalMinutes = intervalMinutes; enabled = true; self.addNewItems = addNewItems; self.updateExistingStates = updateExistingStates; fixedStateRawValue = fixedState?.rawValue }
    var headers: [String] { (try? JSONDecoder().decode([String].self, from: Data(headersJSON.utf8))) ?? [] }
    var mapping: [HTMLImportField] { ((try? JSONDecoder().decode([String].self, from: Data(mappingJSON.utf8))) ?? []).map { HTMLImportField(rawValue: $0) ?? .ignore } }
    var fixedState: ItemState? { fixedStateRawValue.flatMap(ItemState.init(rawValue:)) }
    var tagOptions: TagGenerationOptions { var options = TagGenerationOptions(); options.separators = tagSeparators; options.splitOnWhitespace = splitTagsOnWhitespace; options.generateFromTitle = generateTagsFromTitle; options.titleMode = TitleTagMode(rawValue: titleTagModeRawValue) ?? .firstSegment; options.titleSeparators = titleSeparators; return options }
}

@Model final class EventRecord {
    var id: UUID = UUID(); var itemID: UUID = UUID(); var collectionID: UUID = UUID(); var timestamp: Date = Date(); var type: String = "created"; var note: String?
    init(itemID: UUID, collectionID: UUID, type: String, note: String? = nil) { id = UUID(); self.itemID = itemID; self.collectionID = collectionID; timestamp = .now; self.type = type; self.note = note }
}
