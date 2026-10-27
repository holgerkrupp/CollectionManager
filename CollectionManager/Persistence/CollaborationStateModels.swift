import Foundation
import SwiftData

/// Adds transport metadata only. The domain models remain the frozen V1 types;
/// no released entity identity or stored property is changed.
enum CollectionManagerSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static let models: [any PersistentModel.Type] = CollectionManagerSchemaV1.models + [
        TransportState.self, TransportOwner.self, Zone.self, RecordState.self, Outgoing.self
    ]

    @Model final class TransportState {
        var partition: String = ""
        var scope: String = "private"
        var engineState: Data?
        var historyCursor: Data?
        var handoffStage: String = "pending"
        var bootstrapModelIndex: Int = 0
        var bootstrapOffset: Int = 0
        var legacyState: Data?
        var lastFailure: String?
        init(partition: String, scope: String) { self.partition = partition; self.scope = scope }
    }

    @Model final class TransportOwner {
        var graphPartition: String = ""
        var accountPartition: String = ""
        init(graphPartition: String, accountPartition: String) { self.graphPartition = graphPartition; self.accountPartition = accountPartition }
    }

    @Model final class Zone {
        var partition: String = ""
        var collectionID: UUID = UUID()
        var scope: String = "private"
        var zoneName: String = ""
        var ownerName: String = ""
        var shareRecordName: String?
        var roleRawValue: String = "viewer"
        var authoritative: Bool = false
        var active: Bool = true
        init(partition: String, collectionID: UUID, scope: String, zoneName: String, ownerName: String) {
            self.partition = partition; self.collectionID = collectionID; self.scope = scope; self.zoneName = zoneName; self.ownerName = ownerName
        }
    }

    @Model final class RecordState {
        #Index<RecordState>([\.partition, \.scope, \.zoneName, \.ownerName, \.recordName])
        var partition: String = ""
        var scope: String = "private"
        var zoneName: String = ""
        var ownerName: String = ""
        var recordName: String = ""
        var recordType: String = ""
        var serverModifiedAt: Date?
        var systemFields: Data = Data()
        init(partition: String, scope: String, zoneName: String, ownerName: String, recordName: String) {
            self.partition = partition; self.scope = scope; self.zoneName = zoneName; self.ownerName = ownerName; self.recordName = recordName
        }
    }

    @Model final class Outgoing {
        #Index<Outgoing>([\.partition, \.scope, \.operation], [\.partition, \.scope, \.zoneName, \.ownerName, \.recordName])
        var id: UUID = UUID()
        var partition: String = ""
        var collectionID: UUID = UUID()
        var scope: String = "private"
        var zoneName: String = ""
        var ownerName: String = ""
        var recordName: String = ""
        var recordType: String = ""
        var operation: String = "save"
        var recordArchive: Data?
        var assetData: Data?
        var mutationIDs: Data = Data()
        var createdAt: Date = Date()
        init(partition: String, scope: String, zoneName: String, ownerName: String, recordName: String) {
            self.partition = partition; self.scope = scope; self.zoneName = zoneName; self.ownerName = ownerName; self.recordName = recordName
        }
    }
}

typealias CollectionTransportState = CollectionManagerSchemaV2.TransportState
typealias CollectionTransportOwner = CollectionManagerSchemaV2.TransportOwner
typealias CollectionZone = CollectionManagerSchemaV2.Zone
typealias CollectionCloudRecordState = CollectionManagerSchemaV2.RecordState
typealias CollectionOutgoingSnapshot = CollectionManagerSchemaV2.Outgoing
