import XCTest
import SwiftData
import CloudKit
import CryptoKit
import CollaborationCore
@testable import CollectionManager

@MainActor final class CloudAccountChangeTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, CollectionRecordCodec, CKRecord.ID) {
        let container = try ModelContainer(for: Schema(CollectionManagerSchemaV2.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let user = CKRecord.ID(recordName: "synthetic-original-account")
        let account = SHA256.hash(data: Data(user.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
        return (container, CollectionRecordCodec(modelContainer: container, containerIdentifier: "iCloud.example.account-test", environment: .development, accountPartitionIdentifier: account), user)
    }
    func testInitialSignInForSelectedAccountDoesNotStopDurableSync() async throws {
        let (container, codec, user) = try fixture()
        try await codec.beginHandoff()
        let context = ModelContext(container), id = UUID()
        context.insert(CollectionRecord(id: id, name: "Preserve"))
        context.insert(SyncMutationRecord(collectionID: id, recordName: id.uuidString, recordType: "Collection"))
        try context.save()
        try await codec.handleAccountChange(.signIn(currentUser: user))
        try await codec.saveState(Data([1, 2, 3]), for: .private)
        let saved = try await codec.loadState(for: .private)
        XCTAssertEqual(saved, Data([1, 2, 3]))
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<CollectionRecord>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<SyncMutationRecord>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<CollectionTransportOwner>()), 1)
    }
    func testDifferentSignInAndSignOutDoNotClearOriginalStateOrJournal() async throws {
        let (container, codec, user) = try fixture()
        try await codec.beginHandoff()
        try await codec.saveState(Data([7]), for: .private)
        let context = ModelContext(container)
        context.insert(SyncMutationRecord(collectionID: UUID(), recordName: "pending", recordType: "CollectionItem")); try context.save()
        for change in [CKSyncEngine.Event.AccountChange.ChangeType.signIn(currentUser: CKRecord.ID(recordName: "another-account")), .signOut(previousUser: user), .switchAccounts(previousUser: user, currentUser: CKRecord.ID(recordName: "another-account"))] {
            do { try await codec.handleAccountChange(change); XCTFail("A different or absent account must fail closed") }
            catch { guard case CollectionCodecError.accountPartitionMismatch = error else { return XCTFail("Expected account boundary error") } }
        }
        let saved = try await codec.loadState(for: .private)
        XCTAssertEqual(saved, Data([7]))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<SyncMutationRecord>()), 1)
    }
    func testPersistenceWarningClearsOnlyAfterSuccessfulStateCommit() async throws {
        let (container, codec, _) = try fixture()
        try await codec.beginHandoff()
        await codec.reportStatePersistenceFailure(.unknown, for: .private)
        await codec.setPersistenceFailureForTesting { throw CocoaError(.fileWriteOutOfSpace) }
        do { try await codec.saveState(Data([9]), for: .private); XCTFail("Failed save must not report progress") } catch {}
        let failed = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<CollectionTransportState>()).first { $0.scope == "private" })
        XCTAssertNotNil(failed.lastFailure); XCTAssertNil(failed.engineState)
        await codec.setPersistenceFailureForTesting(nil)
        try await codec.saveState(Data([9]), for: .private)
        let fresh = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<CollectionTransportState>()).first { $0.scope == "private" })
        XCTAssertNil(fresh.lastFailure); XCTAssertEqual(fresh.engineState, Data([9]))
    }
}
