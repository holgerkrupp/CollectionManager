import Foundation
import Observation

/// Owned by AppStore, above every adaptive presentation of a collection.
/// Only explicit user actions mutate drafts; view disappearance does nothing.
@MainActor @Observable final class CollectionEditSession {
    let collectionID: UUID
    private(set) var drafts: [UUID: CollectionItem] = [:]
    var newItemTitle = ""

    init(collectionID: UUID) { self.collectionID = collectionID }

    var hasChanges: Bool { !drafts.isEmpty || !newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var pendingChangeCount: Int { drafts.count }

    func value(for item: CollectionItem) -> CollectionItem { drafts[item.id] ?? item }

    func set(_ value: CollectionItem, original: CollectionItem) {
        guard value.collectionID == collectionID, original.collectionID == collectionID,
              value.id == original.id else { return }
        if value == original { drafts.removeValue(forKey: original.id) }
        else { drafts[original.id] = value }
    }

    func revert() { drafts.removeAll(); newItemTitle = "" }

    @discardableResult
    func saveNewItem(create: (String) -> Bool) -> Bool {
        let title = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return true }
        guard create(title) else { return false }
        newItemTitle = ""
        return true
    }

    func didDelete(_ itemID: UUID) { drafts.removeValue(forKey: itemID) }

    /// Successful rows are acknowledged individually; failed or missing rows
    /// retain the user's input for retry/recovery, including after lost access.
    @discardableResult
    func save(originals: [CollectionItem], canEdit: Bool,
              persist: (CollectionItem, ItemState) -> Bool) -> Bool {
        guard canEdit else { return !hasChanges }
        let originals = Dictionary(originals.filter { $0.collectionID == collectionID }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var allSaved = true
        for id in drafts.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var draft = drafts[id], let original = originals[id] else { allSaved = false; continue }
            if draft == original { drafts.removeValue(forKey: id); continue }
            draft.updatedAt = .now
            draft.consumedAt = draft.state == .consumed ? (original.consumedAt ?? .now) : nil
            if persist(draft, original.state) { drafts.removeValue(forKey: id) }
            else { allSaved = false }
        }
        return allSaved
    }
}

@MainActor @Observable final class CollectionEditSessions {
    private var sessions: [UUID: CollectionEditSession] = [:]

    func session(for collectionID: UUID) -> CollectionEditSession {
        if let session = sessions[collectionID] { return session }
        let session = CollectionEditSession(collectionID: collectionID)
        sessions[collectionID] = session
        return session
    }
}
