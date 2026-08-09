import Foundation
import SwiftUI
import UIKit

struct ItemState: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    nonisolated init(rawValue: String) { self.rawValue = rawValue }

    static let wanted = ItemState(rawValue: "wanted")
    static let acquired = ItemState(rawValue: "acquired")
    static let stored = ItemState(rawValue: "stored")
    static let inProgress = ItemState(rawValue: "inProgress")
    static let consumed = ItemState(rawValue: "consumed")
    static let archived = ItemState(rawValue: "archived")
    static let allCases = [wanted, acquired, stored, inProgress, consumed, archived]

    var id: String { rawValue }
    var label: String {
        switch rawValue {
        case Self.wanted.rawValue: "Want to Try"
        case Self.acquired.rawValue: "Acquired"
        case Self.stored.rawValue: "In Storage"
        case Self.inProgress.rawValue: "In Progress"
        case Self.consumed.rawValue: "Consumed"
        case Self.archived.rawValue: "Archived"
        default: rawValue.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
    var color: Color {
        switch rawValue {
        case Self.wanted.rawValue: .orange
        case Self.acquired.rawValue: .blue
        case Self.stored.rawValue: .teal
        case Self.inProgress.rawValue: .purple
        case Self.consumed.rawValue: .green
        case Self.archived.rawValue: .gray
        default: .accentColor
        }
    }
    var symbol: String {
        switch rawValue {
        case Self.wanted.rawValue: "bookmark"
        case Self.acquired.rawValue: "bag"
        case Self.stored.rawValue: "shippingbox"
        case Self.inProgress.rawValue: "play"
        case Self.consumed.rawValue: "checkmark.circle"
        case Self.archived.rawValue: "archivebox"
        default: "circle"
        }
    }
}

enum StatusColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case orange, blue, teal, purple, green, gray, red, pink, indigo, yellow

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .orange: .orange
        case .blue: .blue
        case .teal: .teal
        case .purple: .purple
        case .green: .green
        case .gray: .gray
        case .red: .red
        case .pink: .pink
        case .indigo: .indigo
        case .yellow: .yellow
        }
    }
}

struct CollectionStatus: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var color: StatusColor
    var symbol: String

    init(id: String = UUID().uuidString, name: String, color: StatusColor = .blue, symbol: String = "circle") {
        self.id = id
        self.name = name
        self.color = color
        self.symbol = symbol
    }

    static let defaults: [CollectionStatus] = [
        .init(id: ItemState.wanted.rawValue, name: ItemState.wanted.label, color: .orange, symbol: ItemState.wanted.symbol),
        .init(id: ItemState.acquired.rawValue, name: ItemState.acquired.label, color: .blue, symbol: ItemState.acquired.symbol),
        .init(id: ItemState.stored.rawValue, name: ItemState.stored.label, color: .teal, symbol: ItemState.stored.symbol),
        .init(id: ItemState.inProgress.rawValue, name: ItemState.inProgress.label, color: .purple, symbol: ItemState.inProgress.symbol),
        .init(id: ItemState.consumed.rawValue, name: ItemState.consumed.label, color: .green, symbol: ItemState.consumed.symbol),
        .init(id: ItemState.archived.rawValue, name: ItemState.archived.label, color: .gray, symbol: ItemState.archived.symbol)
    ]

    static func fallback(for state: ItemState) -> CollectionStatus {
        defaults.first(where: { $0.id == state.rawValue }) ?? CollectionStatus(id: state.rawValue, name: state.label, color: .gray, symbol: state.symbol)
    }
}

enum CollectionCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case food
    case games
    case boardGames
    case books
    case music
    case cosmetics
    case petFood
    case products
    case custom

    var id: String { rawValue }
    var name: String {
        switch self { case .food: "Food & Drinks"; case .games: "Video Games"; case .boardGames: "Board Games"; case .books: "Books"; case .music: "Music"; case .cosmetics: "Cosmetics"; case .petFood: "Pet Food"; case .products: "Other Products"; case .custom: "Custom" }
    }
    // Games is intentionally ready for a future personal EAN API, but does not
    // claim scanner/product-lookup support until that provider is configured.
    var supportsBarcodeScanning: Bool { self != .custom && barcodeProviderAvailable }
    var barcodeProviderAvailable: Bool {
        switch self {
        case .food: true
        case .games: !GamesEANAPIKeyStore.load().isEmpty
        case .boardGames, .books, .music, .cosmetics, .petFood, .products: true
        case .custom: false
        }
    }
    var detailFields: [(key: String, title: String, placeholder: String)] {
        switch self {
        case .food:
            return [("country", "Country", "e.g. Germany"), ("categories", "Categories", "e.g. soda, energy drink")]
        case .games:
            return [("publisher", "Publisher", "e.g. Nintendo"), ("platform", "Platform", "e.g. Switch"), ("genre", "Genre", "e.g. strategy"), ("releaseYear", "Release year", "e.g. 2024"), ("players", "Players", "e.g. 2–4")]
        case .boardGames:
            return [("bggID", "BoardGameGeek ID", "e.g. 174430"), ("publisher", "Publisher", "e.g. Cephalofair"), ("players", "Players", "e.g. 1–4"), ("playingTime", "Playing time", "e.g. 120 minutes")]
        case .books:
            return [("authors", "Authors", "e.g. Ursula K. Le Guin"), ("publisher", "Publisher", "e.g. Penguin"), ("publishedDate", "Published", "e.g. 1968"), ("pages", "Pages", "e.g. 304")]
        case .music:
            return [("artist", "Artist", "e.g. The Beatles"), ("releaseDate", "Release date", "e.g. 1967"), ("country", "Country", "e.g. GB"), ("format", "Format", "e.g. CD")]
        case .cosmetics:
            return [("categories", "Categories", "e.g. shampoo"), ("country", "Country", "e.g. France")]
        case .petFood:
            return [("categories", "Categories", "e.g. dog food"), ("country", "Country", "e.g. Germany")]
        case .products:
            return [("categories", "Categories", "e.g. toy, household"), ("manufacturer", "Manufacturer", "e.g. Acme")]
        case .custom:
            return []
        }
    }
}

struct Barcode: Hashable, Codable, Sendable {
    let value: String; let type: String
    init?(rawValue: String, type: String = "EAN-13") {
        let digits = rawValue.filter(\.isNumber)
        guard [8, 12, 13, 14].contains(digits.count), Self.hasValidCheckDigit(digits) else { return nil }
        value = digits.count == 12 ? "0\(digits)" : digits
        self.type = digits.count == 12 ? "UPC-A" : type
    }

    private static func hasValidCheckDigit(_ digits: String) -> Bool {
        guard let checkDigit = digits.last.flatMap({ Int(String($0)) }) else { return false }
        let body = digits.dropLast().reversed().enumerated()
        let sum = body.reduce(0) { partial, entry in
            let digit = Int(String(entry.element)) ?? 0
            return partial + digit * (entry.offset.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - (sum % 10)) % 10 == checkDigit
    }
}

enum MetadataValue: Codable, Hashable, Sendable {
    case string(String), integer(Int), decimal(Double), boolean(Bool), date(Date), url(URL)
    var displayValue: String { switch self { case .string(let v): v; case .integer(let v): "\(v)"; case .decimal(let v): "\(v)"; case .boolean(let v): v ? "Yes" : "No"; case .date(let v): v.formatted(date: .abbreviated, time: .omitted); case .url(let v): v.absoluteString } }
}

struct CollectionModel: Identifiable, Hashable, Sendable {
    let id: UUID; var name: String; var icon: String; var subtitle: String; var category: CollectionCategory = .custom; var statuses: [CollectionStatus] = CollectionStatus.defaults; var mergedTags: [MergedTagRule] = []; var role: CollectionMemberRole = .owner

    func status(for state: ItemState) -> CollectionStatus {
        statuses.first(where: { $0.id == state.rawValue }) ?? CollectionStatus.fallback(for: state)
    }
}

enum CollectionMemberRole: String, Codable, CaseIterable, Sendable {
    case owner, editor, viewer

    var canEdit: Bool { self == .owner || self == .editor }
    var canDelete: Bool { self == .owner }
}

enum CollectionSyncState: String, Sendable {
    case idle, syncing, pending, error
}

struct MergedTagRule: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sourceTags: [String]
    var mergedTag: String

    init(id: UUID = UUID(), sourceTags: [String], mergedTag: String) {
        self.id = id
        self.sourceTags = sourceTags
        self.mergedTag = mergedTag
    }
}

struct CollectionSettingsPayload: Codable, Sendable {
    var category: CollectionCategory = .custom
    var statuses: [CollectionStatus] = CollectionStatus.defaults
    var mergedTags: [MergedTagRule] = []

    private enum CodingKeys: String, CodingKey { case category, statuses, statusLabels, mergedTags }

    init(category: CollectionCategory = .custom, statuses: [CollectionStatus] = CollectionStatus.defaults, mergedTags: [MergedTagRule] = []) {
        self.category = category
        self.statuses = statuses
        self.mergedTags = mergedTags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.category = try container.decodeIfPresent(CollectionCategory.self, forKey: .category) ?? .custom
        if let statuses = try container.decodeIfPresent([CollectionStatus].self, forKey: .statuses) {
            self.statuses = statuses
        } else if let labels = try container.decodeIfPresent([String: String].self, forKey: .statusLabels) {
            self.statuses = CollectionStatus.defaults.map { status in
                var updated = status
                updated.name = labels[status.id] ?? status.name
                return updated
            }
        } else {
            self.statuses = CollectionStatus.defaults
        }
        self.mergedTags = try container.decodeIfPresent([MergedTagRule].self, forKey: .mergedTags) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(category, forKey: .category)
        try container.encode(statuses, forKey: .statuses)
        try container.encode(mergedTags, forKey: .mergedTags)
    }
}

struct CollectionItem: Identifiable, Hashable, Sendable {
    let id: UUID; let collectionID: UUID; var title: String; var brand: String; var variant: String; var itemDescription: String; var state: ItemState; var quantity: Int; var barcode: Barcode?; var createdAt: Date; var updatedAt: Date; var consumedAt: Date?; var tags: [String]; var metadata: [String: MetadataValue]; var imageSystemName: String; var imageData: Data?; var importSourceKey: String?; var dateTags: [String: Date] = [:]; var ratings: [ItemRating] = []; var comments: [ItemComment] = []
    var earliestDateTag: Date? { dateTags.values.min() }
}

struct ItemRating: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let itemID: UUID
    let participantID: String
    var participantName: String
    var value: Int
    var updatedAt: Date
}

struct ItemComment: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let itemID: UUID
    let participantID: String
    var participantName: String
    var text: String
    let createdAt: Date
    var updatedAt: Date
}

struct CollaboratorIdentity: Sendable {
    let id: String
    let displayName: String

    static var current: CollaboratorIdentity {
        let defaults = UserDefaults.standard
        let idKey = "collaborator.identity.id"
        let nameKey = "collaborator.identity.name"
        let id = defaults.string(forKey: idKey) ?? {
            let value = "local-\(UUID().uuidString)"
            defaults.set(value, forKey: idKey)
            return value
        }()
        let name = defaults.string(forKey: nameKey) ?? {
            let value = UIDevice.current.name.isEmpty ? "Collaborator" : UIDevice.current.name
            defaults.set(value, forKey: nameKey)
            return value
        }()
        return CollaboratorIdentity(id: id, displayName: name)
    }
}

enum CollaborationRecordNames {
    static func rating(itemID: UUID, participantID: String) -> String {
        itemID.uuidString + "-rating-" + participantID
    }

    static func comment(_ id: UUID) -> String { id.uuidString }
}

struct CollectionProductMatch: Identifiable, Sendable {
    let id: UUID
    let collectionName: String
    let itemTitle: String
    let state: ItemState
    let status: CollectionStatus
    let matchedBy: [String]
}

enum ItemSort: String, CaseIterable, Identifiable, Sendable {
    case updatedDescending
    case titleAscending
    case dateAscending
    case dateDescending

    var id: String { rawValue }
    var label: String {
        switch self {
        case .updatedDescending: "Recently updated"
        case .titleAscending: "Title"
        case .dateAscending: "Date (oldest first)"
        case .dateDescending: "Date (newest first)"
        }
    }
}

struct CollectionSettings: Sendable { var statuses: [CollectionStatus]; var defaultState: ItemState; var requireBarcode: Bool; var defaultTags: [String] }

struct ItemEvent: Identifiable, Sendable { let id: UUID; let itemID: UUID; let timestamp: Date; let type: String; let note: String? }
