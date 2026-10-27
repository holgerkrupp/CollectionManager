import CloudKit
import CollaborationCloudKit
import XCTest
@testable import CollectionManager

@MainActor
final class SharingSessionTests: XCTestCase {
    func testRootResolverKeepsIndependentZonesAndStableRecordIDs() throws {
        let resolver = CollectionShareRootResolver()
        let ids = [UUID(), UUID()]
        for id in ids {
            let zone = CKRecordZone.ID(zoneName: "collection-\(id.uuidString)", ownerName: CKCurrentUserDefaultName)
            let record = CKRecord(recordType: "Collection", recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zone))
            resolver.setPlan(CloudKitShareRootPlan(rootID: id.uuidString, title: "Fixture", rootRecord: record, topology: .hierarchy), for: id)
        }
        XCTAssertNotEqual(try resolver.plan(for: ids[0].uuidString).rootRecord.recordID.zoneID,
                          try resolver.plan(for: ids[1].uuidString).rootRecord.recordID.zoneID)
        XCTAssertEqual(try resolver.plan(for: ids[0].uuidString).rootRecord.recordID.recordName, ids[0].uuidString)
        XCTAssertThrowsError(try resolver.plan(for: UUID().uuidString))
    }

    func testNewShareOwnerMatchesCloudKitParticipant() {
        let share = CKShare(rootRecord: CKRecord(recordType: "Fixture", recordID: CKRecord.ID(recordName: "root", zoneID: CKRecordZone.ID(zoneName: "fixture-zone", ownerName: CKCurrentUserDefaultName))))
        let access = CollectionSharingSession.authoritativeAccess(for: share)
        XCTAssertEqual(share.currentUserParticipant?.role, .owner)
        XCTAssertTrue(access.canEdit)
        XCTAssertTrue(access.canManageShare)
    }

    func testSharingErrorsDoNotExposeUnderlyingContent() {
        let error = NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "private invitation URL and participant"])
        let message = CollectionSharingSession.message(for: error)
        XCTAssertFalse(message.contains("private invitation"))
        XCTAssertFalse(message.contains("participant"))
    }
}
