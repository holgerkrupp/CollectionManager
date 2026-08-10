import Foundation
import SwiftData

struct WebSyncApplyResult: Sendable {
    var added = 0
    var updated = 0
    var addedItems: [String] = []
    var matchedStateChanges: [AutomaticSyncStateChange] = []
}

struct WebSyncResult: Sendable {
    var added = 0
    var updated = 0
    var error: String?
    var collectionName = "Collection"
    var addedItems: [String] = []
    var matchedStateChanges: [AutomaticSyncStateChange] = []
}

@MainActor final class HTMLSyncCoordinator {
    private let repository: CollectionRepository
    init(context: ModelContext) { repository = CollectionRepository(context: context) }
    func sync(_ configuration: WebSyncRecord) async -> WebSyncResult {
        guard configuration.enabled, let url = URL(string: configuration.urlString) else { return WebSyncResult(error: "Invalid web source URL.") }
        do {
            let tables = try await HTMLImporter().load(url: url)
            guard let table = tables.first(where: { $0.name == configuration.tableName }) ?? tables.first else { throw HTMLImportError.noObjects }
            let metadataFields = repository.metadataFields(for: configuration.collectionID)
            let mapping: [ImportColumnDestination]
            if configuration.mapping.count == table.headers.count {
                mapping = configuration.mapping
            } else {
                // A changed table layout may reveal new columns. Background sync
                // never creates collection fields silently; the editor can map them.
                mapping = HTMLImporter().suggestMapping(for: table, existingMetadataFields: metadataFields).map { destination in
                    if case .newMetadata = destination { return .ignore }
                    return destination
                }
            }
            let drafts = HTMLImporter().prepareImport(from: table, mapping: mapping, existingMetadataFields: metadataFields).drafts.map { draft in
                var updated = draft
                updated.tags = TagUtilities.tags(title: draft.title, existing: draft.tags, rawTags: draft.tags.joined(separator: ","), options: configuration.tagOptions)
                return updated
            }
            let existingSourceKeys = repository.importedSourceKeys(in: configuration.collectionID)
            var entries: [(draft: ImportDraft, sourceKey: String, updateExistingState: Bool)] = []
            for draft in drafts {
                let key = sourceKey(configuration, draft: draft)
                var effectiveDraft = draft
                if let fixedState = configuration.fixedState { effectiveDraft.state = fixedState }
                if !configuration.addNewItems && !existingSourceKeys.contains(key) { continue }
                entries.append((effectiveDraft, key, configuration.updateExistingStates))
            }
            let counts = repository.applyWebDrafts(entries, collectionID: configuration.collectionID)
            let result = WebSyncResult(added: counts.added, updated: counts.updated, collectionName: repository.collectionName(for: configuration.collectionID), addedItems: counts.addedItems, matchedStateChanges: counts.matchedStateChanges)
            repository.setWebSync(configuration, lastSyncAt: .now, error: nil)
            return result
        } catch { repository.setWebSync(configuration, lastSyncAt: configuration.lastSyncAt, error: error.localizedDescription); return WebSyncResult(error: error.localizedDescription) }
    }
    private func sourceKey(_ configuration: WebSyncRecord, draft: ImportDraft) -> String { let raw = draft.sourceIdentifier?.isEmpty == false ? draft.sourceIdentifier! : "\(draft.title)|\(draft.brand)|\(draft.variant)"; return "\(configuration.id.uuidString)|\(raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))" }
}
