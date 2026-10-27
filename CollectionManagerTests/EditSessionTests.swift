import XCTest
@testable import CollectionManager

@MainActor final class EditSessionTests: XCTestCase {
    func testDraftSurvivesReplacementOfAdaptiveChildrenAndCollectionNavigation() {
        let registry = CollectionEditSessions()
        let id = UUID()
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: id)[0]
        var changed = item
        changed.title = "Changed title"
        changed.brand = "Changed brand"
        changed.metadata["notes"] = .string("Draft notes")
        let firstTableSession = registry.session(for: id)
        firstTableSession.set(changed, original: item)
        firstTableSession.newItemTitle = "New item draft"
        // Cards, compact/regular, Split View and a replacement table all resolve
        // the same owner above their lifetimes. Another collection is isolated.
        XCTAssertFalse(registry.session(for: UUID()).hasChanges)
        let replacementTableSession = registry.session(for: id)
        XCTAssertTrue(firstTableSession === replacementTableSession)
        XCTAssertEqual(replacementTableSession.value(for: item), changed)
        XCTAssertEqual(replacementTableSession.newItemTitle, "New item draft")
        XCTAssertEqual(item.title, "Fixture item 0")
    }

    func testFailedSaveAndLostPermissionPreserveDraftUntilExplicitRevert() {
        let id = UUID()
        let session = CollectionEditSession(collectionID: id)
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: id)[0]
        var changed = item
        changed.title = "Unsaved"
        session.set(changed, original: item)
        var calls = 0
        XCTAssertFalse(session.save(originals: [item], canEdit: false) { _, _ in calls += 1; return true })
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(session.save(originals: [item], canEdit: true) { _, _ in false })
        XCTAssertEqual(session.value(for: item).title, "Unsaved")
        XCTAssertFalse(session.save(originals: [], canEdit: true) { _, _ in XCTFail("Missing rows must not be reinserted"); return true })
        session.revert()
        XCTAssertFalse(session.hasChanges)
        XCTAssertEqual(session.value(for: item), item)
    }

    func testExplicitSaveAcknowledgesOnlySuccessfulRows() {
        let id = UUID()
        let session = CollectionEditSession(collectionID: id)
        let originals = CollectionPerformanceFixture.items(count: 2, collectionID: id)
        for item in originals {
            var changed = item
            changed.brand = "Draft brand"
            session.set(changed, original: item)
        }
        XCTAssertFalse(session.save(originals: originals, canEdit: true) { item, _ in item.id == originals[0].id })
        XCTAssertNil(session.drafts[originals[0].id])
        XCTAssertNotNil(session.drafts[originals[1].id])
        XCTAssertTrue(session.save(originals: originals, canEdit: true) { item, previousState in
            XCTAssertEqual(item.brand, "Draft brand")
            XCTAssertEqual(previousState, originals[1].state)
            return true
        })
        XCTAssertFalse(session.hasChanges)
    }

    func testNewItemInputSurvivesFailedCreation() {
        let session = CollectionEditSession(collectionID: UUID())
        session.newItemTitle = "  Pending new item  "
        XCTAssertFalse(session.saveNewItem { _ in false })
        XCTAssertTrue(session.hasChanges)
        XCTAssertTrue(session.saveNewItem { title in
            XCTAssertEqual(title, "Pending new item")
            return true
        })
        XCTAssertFalse(session.hasChanges)
    }

    func testForeignCollectionCannotEnterSession() {
        let session = CollectionEditSession(collectionID: UUID())
        let item = CollectionPerformanceFixture.items(count: 1, collectionID: UUID())[0]
        var changed = item
        changed.title = "Foreign"
        session.set(changed, original: item)
        XCTAssertFalse(session.hasChanges)
    }
}
