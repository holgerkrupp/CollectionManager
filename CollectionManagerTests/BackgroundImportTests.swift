import XCTest
import SwiftData
@testable import CollectionManager

/// Test-only synchronization. Production repositories remain non-Sendable;
/// this gate protects its own small state with NSCondition and never holds a
/// ModelContext or model instance.
nonisolated private final class InterleavedImportSaveGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var staged = false
    private var released = false

    var hasStaged: Bool {
        condition.lock(); defer { condition.unlock() }
        return staged
    }

    func pauseBeforeSave() throws {
        condition.lock(); defer { condition.unlock() }
        staged = true; condition.broadcast()
        let deadline = Date().addingTimeInterval(10)
        while !released {
            guard condition.wait(until: deadline) else { throw CocoaError(.userCancelled) }
        }
    }

    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true; condition.broadcast()
    }
}

@MainActor final class BackgroundImportTests: XCTestCase {
    private func fixture(requiredBarcode: Bool = false, viewer: Bool = false) throws -> (ModelContainer, CollectionRepository, CollectionModel) {
        let container = try ModelContainer(for: Schema(CollectionManagerSchemaV1.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container), repository = CollectionRepository(context: context)
        try repository.addCollection(name: "Background import", icon: "books.vertical", subtitle: "")
        var collection = try XCTUnwrap(repository.collections().first)
        collection.defaultStatusID = "stored"; collection.barcodeRequired = requiredBarcode
        try repository.updateCollection(collection)
        if viewer {
            let member = try XCTUnwrap(context.fetch(FetchDescriptor<CollectionMemberRecord>()).first)
            member.roleRawValue = "viewer"; try context.save()
        }
        return (container, repository, collection)
    }

    private func draft(_ title: String, barcode: Barcode? = nil, explicit: Bool = false, state: ItemState = .wanted) -> ImportDraft {
        ImportDraft(title: title, brand: "", variant: "", description: "", state: state, quantity: 1, tags: [], barcode: barcode, stateWasExplicit: explicit)
    }

    func testNewDraftImportCommitsOffMainThreadWithEventsAndIntent() async throws {
        let (container, repository, collection) = try fixture()
        let background = CollectionBackgroundRepository(container: container)
        try await background.importNewDrafts([draft("First"), draft("Second")], collectionID: collection.id, allowsDuplicates: false) { point in
            if case .save = point { XCTAssertFalse(Thread.isMainThread, "The actual import commit must leave the UI executor") }
        }
        let context = ModelContext(container)
        XCTAssertEqual(try repository.items(in: collection.id).count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EventRecord>()), 4)
        let mutations = try repository.pendingMutations()
        XCTAssertEqual(mutations.filter { $0.recordType == "CollectionItem" }.count, 2)
        XCTAssertEqual(mutations.filter { $0.recordType == "CollectionEvent" }.count, 4)
    }

    func testFailedNewDraftCommitRollsBackItemsEventsAndNewIntentTogether() async throws {
        let (container, repository, collection) = try fixture()
        let baseline = try repository.pendingMutations().count
        do {
            try await CollectionBackgroundRepository(container: container).importNewDrafts([draft("First"), draft("Second")], collectionID: collection.id, allowsDuplicates: false) { point in
                if case .save = point { throw CocoaError(.fileWriteOutOfSpace) }
            }
            XCTFail("Injected commit must fail")
        } catch { XCTAssertTrue(error is RepositoryError) }
        XCTAssertTrue(try repository.items(in: collection.id).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<EventRecord>()), 0)
        XCTAssertEqual(try repository.pendingMutations().count, baseline)
    }

    func testFailedSourceUpdateCommitPreservesOriginalItemAndJournal() async throws {
        let (container, repository, collection) = try fixture()
        let background = CollectionBackgroundRepository(container: container)
        try await background.importDrafts([(draft("Original"), "stable-source")], collectionID: collection.id)
        let original = try XCTUnwrap(repository.items(in: collection.id).first)
        let baseline = try repository.pendingMutations().count
        let events = try ModelContext(container).fetchCount(FetchDescriptor<EventRecord>())
        do {
            try await background.importDrafts([(draft("Should roll back"), "stable-source"), (draft("New"), "new-source")], collectionID: collection.id) { point in
                if case .save = point { throw CocoaError(.fileWriteOutOfSpace) }
            }
            XCTFail("Injected commit must fail")
        } catch { XCTAssertTrue(error is RepositoryError) }
        let after = try repository.items(in: collection.id)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.id, original.id)
        XCTAssertEqual(after.first?.title, "Original")
        XCTAssertEqual(try repository.pendingMutations().count, baseline)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<EventRecord>()), events)
    }

    func testViewerCannotUseEitherBackgroundImportBoundary() async throws {
        let (container, repository, collection) = try fixture(viewer: true)
        let background = CollectionBackgroundRepository(container: container)
        let baseline = try repository.pendingMutations().count
        do { try await background.importNewDrafts([draft("Forbidden")], collectionID: collection.id, allowsDuplicates: true); XCTFail("Viewer import must fail") }
        catch { XCTAssertTrue(error is RepositoryError) }
        do { try await background.importDrafts([(draft("Forbidden"), "source")], collectionID: collection.id); XCTFail("Viewer source import must fail") }
        catch { XCTAssertTrue(error is RepositoryError) }
        XCTAssertTrue(try repository.items(in: collection.id).isEmpty)
        XCTAssertEqual(try repository.pendingMutations().count, baseline)
    }

    func testRequiredBarcodeRejectsNewBatchButSourceUpdateRetainsExistingBarcode() async throws {
        let (container, repository, collection) = try fixture(requiredBarcode: true)
        let background = CollectionBackgroundRepository(container: container)
        let barcode = try XCTUnwrap(Barcode(rawValue: "036000291452"))
        do {
            try await background.importNewDrafts([draft("Valid first", barcode: barcode), draft("Missing")], collectionID: collection.id, allowsDuplicates: false)
            XCTFail("Preflight must reject whole batch")
        } catch { XCTAssertTrue(error is RepositoryError) }
        XCTAssertTrue(try repository.items(in: collection.id).isEmpty)
        try await background.importDrafts([(draft("Original", barcode: barcode), "source")], collectionID: collection.id)
        let original = try XCTUnwrap(repository.items(in: collection.id).first)
        try await background.importDrafts([(draft("Updated without repeated barcode"), "source")], collectionID: collection.id)
        let updated = try XCTUnwrap(repository.items(in: collection.id).first)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.barcode, barcode)
        XCTAssertEqual(updated.title, "Updated without repeated barcode")
        do { try await background.importDrafts([(draft("New source missing barcode"), "other")], collectionID: collection.id); XCTFail("New source requires barcode") }
        catch { XCTAssertTrue(error is RepositoryError) }
        XCTAssertEqual(try repository.items(in: collection.id).count, 1)
    }

    func testBackgroundImportsUseStoredDefaultsAndPreserveExplicitStatusAndDuplicatePolicy() async throws {
        let (container, repository, collection) = try fixture()
        let background = CollectionBackgroundRepository(container: container)
        try await background.importNewDrafts([draft("Default"), draft("Explicit", explicit: true, state: .wanted), draft("Default")], collectionID: collection.id, allowsDuplicates: false)
        let first = try repository.items(in: collection.id)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first { $0.title == "Default" }?.state, .stored)
        XCTAssertEqual(first.first { $0.title == "Explicit" }?.state, .wanted)
        try await background.importNewDrafts([draft("Default")], collectionID: collection.id, allowsDuplicates: true)
        XCTAssertEqual(try repository.items(in: collection.id).count, 3)
        try await background.importDrafts([(draft("Source default"), "source")], collectionID: collection.id)
        XCTAssertEqual(try repository.items(in: collection.id).first { $0.title == "Source default" }?.state, .stored)
    }
    func testAppStoreUsesExplicitImportTargetAndPreservesExistingRequiredBarcode() async throws {
        let (container, repository, target) = try fixture(requiredBarcode: true)
        let barcode = try XCTUnwrap(Barcode(rawValue: "036000291452"))
        try repository.importDrafts([(draft("Original", barcode: barcode), "stable-source")], collectionID: target.id)
        try repository.addCollection(name: "Other collection", icon: "books.vertical", subtitle: "")
        let other = try XCTUnwrap(repository.collections().first { $0.id != target.id })
        let store = AppStore()
        store.configure(context: container.mainContext, container: container)
        store.load()
        store.select(other.id)
        var update = draft("Updated source")
        update.sourceIdentifier = "stable-source"
        let committed = await store.importDrafts([update], collectionID: target.id)
        XCTAssertTrue(committed)
        XCTAssertEqual(store.selectedCollection?.id, other.id)
        XCTAssertTrue(store.items.isEmpty)
        let fresh = CollectionRepository(context: ModelContext(container))
        let updated = try XCTUnwrap(fresh.items(in: target.id).first)
        XCTAssertEqual(updated.title, "Updated source")
        XCTAssertEqual(updated.barcode, barcode)
        XCTAssertTrue(try fresh.items(in: other.id).isEmpty)
    }

    func testInterleavedBackgroundImportCannotSilentlyOverwriteLaterManualEdit() async throws {
        let (container, repository, collection) = try fixture(requiredBarcode: true)
        let background = CollectionBackgroundRepository(container: container)
        let barcode = try XCTUnwrap(Barcode(rawValue: "036000291452"))
        try await background.importDrafts([(draft("Original", barcode: barcode), "stable-source")], collectionID: collection.id)
        let original = try XCTUnwrap(repository.items(in: collection.id).first)
        let gate = InterleavedImportSaveGate()
        defer { gate.release() }
        let backgroundDraft = draft("Older background title")
        let importTask = Task {
            try await background.importDrafts([(backgroundDraft, "stable-source")], collectionID: collection.id) { point in
                if case .save = point { try gate.pauseBeforeSave() }
            }
        }

        // Wait asynchronously: the MainActor remains free to perform the manual
        // save while the background actor is paused immediately before commit.
        let deadline = Date().addingTimeInterval(10)
        while !gate.hasStaged && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard gate.hasStaged else {
            gate.release()
            _ = try? await importTask.value
            return XCTFail("Background import did not reach its bounded save checkpoint")
        }
        let beforeManual = Set(try repository.pendingMutations().map(\.id))
        var manual = original
        manual.title = "Later manual title"
        manual.updatedAt = Date().addingTimeInterval(1)
        try repository.updateItem(manual)
        let manualIntentIDs = Set(try repository.pendingMutations().map(\.id)).subtracting(beforeManual)
        XCTAssertFalse(manualIntentIDs.isEmpty)
        gate.release()

        do { try await importTask.value }
        catch {
            guard let typed = error as? RepositoryError, case .saveFailed = typed else {
                return XCTFail("Only an explicit failed-save outcome may reject this interleaving")
            }
        }
        // A fresh context checks committed data, rather than a possibly cached
        // optimistic value still registered in the main repository's context.
        let reopened = CollectionRepository(context: ModelContext(container))
        let retained = try XCTUnwrap(reopened.item(id: original.id))
        XCTAssertEqual(retained.title, manual.title, "An older staged import must not silently replace the later manual edit")
        XCTAssertEqual(retained.updatedAt, manual.updatedAt)
        XCTAssertEqual(retained.barcode, barcode)
        XCTAssertEqual(retained.importSourceKey, "stable-source")
        XCTAssertTrue(Set(try reopened.pendingMutations().map(\.id)).isSuperset(of: manualIntentIDs), "The committed manual edit must retain its durable outgoing intent")
    }

    func testFailedImportRollsBackNewMetadataFieldsWithItemsAndIntent() async throws {
        let (container, repository, collection) = try fixture()
        let baseline = try repository.pendingMutations().count
        let field = MetadataFieldDefinition(name: "Atomic imported field", type: .text)
        var imported = draft("Imported")
        imported.metadata[field.storageKey] = .string("Retained only on success")
        do {
            try await CollectionBackgroundRepository(container: container).importNewDrafts([imported], collectionID: collection.id,
                allowsDuplicates: false, metadataFieldsToCreate: [field]) { point in
                    if case .save = point { throw CocoaError(.fileWriteOutOfSpace) }
                }
            XCTFail("Injected failure must reject the whole import")
        } catch { XCTAssertTrue(error is RepositoryError) }
        let reopened = CollectionRepository(context: ModelContext(container))
        XCTAssertFalse(try reopened.metadataFields(for: collection.id).contains { $0.id == field.id })
        XCTAssertTrue(try reopened.items(in: collection.id).isEmpty)
        XCTAssertEqual(try reopened.pendingMutations().count, baseline)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<EventRecord>()), 0)
    }

}
