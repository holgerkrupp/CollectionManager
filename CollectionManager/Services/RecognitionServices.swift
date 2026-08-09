import Foundation
import Vision
import ImageIO
import Security

struct OCRResult: Sendable { var text: String; var lines: [String] }

struct OCRService: Sendable {
    func recognizeText(in imageData: Data) async throws -> OCRResult {
        try await Task.detached(priority: .userInitiated) {
            guard let image = CGImageSourceCreateWithData(imageData as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { throw RecognitionError.invalidImage }
            var lines: [String] = []
            let request = VNRecognizeTextRequest { request, error in guard error == nil else { return }; lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? [] }
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return OCRResult(text: lines.joined(separator: "\n"), lines: lines)
        }.value
    }
}

protocol ProductMetadataProvider: Sendable { func product(for barcode: Barcode) async throws -> ProductMetadata? }
struct ProductMetadata: Sendable { var title: String; var brand: String; var variant: String; var quantity: String?; var categories: [String]; var country: String?; var imageURL: URL?; var extraFields: [String: String] = [:] }

enum GamesEANAPIKeyStore {
    private static let service = "CollectionManager.GamesEAN"
    private static let account = "api-key"

    static func load() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ value: String) {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SecItemDelete(query as CFDictionary)
        } else if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) != errSecSuccess {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

enum ProductLookupError: LocalizedError, Sendable {
    case missingAPIKey
    case unauthorized
    case invalidResponse
    case rateLimited
    case serviceUnavailable
    case network(URLError.Code)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add the Games EAN API key in Settings before looking up games."
        case .unauthorized: "The Games EAN API key was rejected. Check the key in Settings."
        case .invalidResponse: "The product service returned an invalid response."
        case .rateLimited: "The product service is temporarily rate-limiting requests. Try again shortly."
        case .serviceUnavailable: "The product service is temporarily unavailable."
        case .network: "The product lookup could not reach the internet."
        }
    }
}

actor ProductMetadataCache {
    static let shared = ProductMetadataCache()
    private var values: [String: ProductMetadata] = [:]
    func value(for key: String) -> ProductMetadata? { values[key] }
    func insert(_ value: ProductMetadata, for key: String) { values[key] = value }
}

struct OpenFoodFactsProvider: ProductMetadataProvider {
    private struct Response: Decodable { let status: Int; let product: Product? }
    private struct Product: Decodable { let productName: String?; let brands: String?; let quantity: String?; let categories: String?; let countries: String?; let imageURL: String?; enum CodingKeys: String, CodingKey { case productName = "product_name", brands, quantity, categories, countries, imageURL = "image_url" } }
    func product(for barcode: Barcode) async throws -> ProductMetadata? {
        if let cached = await ProductMetadataCache.shared.value(for: barcode.value) { return cached }
        let endpoint = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode.value).json")!
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: 15)
                request.setValue("CollectionManager/1.0 (iOS; contact via app settings)", forHTTPHeaderField: "User-Agent")
                request.setValue("product_name,brands,quantity,categories,countries,image_url", forHTTPHeaderField: "Fields")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ProductLookupError.invalidResponse }
                if http.statusCode == 429 { throw ProductLookupError.rateLimited }
                guard (200..<300).contains(http.statusCode) else { throw ProductLookupError.serviceUnavailable }
                let result = try JSONDecoder().decode(Response.self, from: data)
                guard result.status == 1, let product = result.product, let title = product.productName, !title.isEmpty else { return nil }
                let metadata = ProductMetadata(title: title, brand: product.brands ?? "", variant: product.quantity ?? "", quantity: product.quantity, categories: product.categories?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [], country: product.countries, imageURL: product.imageURL.flatMap(URL.init(string:)))
                await ProductMetadataCache.shared.insert(metadata, for: barcode.value)
                return metadata
            } catch let error as ProductLookupError {
                lastError = error
                if case .rateLimited = error { break }
            } catch let error as URLError {
                lastError = ProductLookupError.network(error.code)
            } catch {
                lastError = ProductLookupError.invalidResponse
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(300 * (attempt + 1))) }
        }
        throw lastError ?? ProductLookupError.serviceUnavailable
    }
}

struct GamesEANProvider: ProductMetadataProvider {
    

    
    private struct Game: Decodable {
        let name: String?
        let source: String?
        let sourceID: String?
        let ean: String?
        let platform: String?
        let cover: URL?
        let region: String?
        enum CodingKeys: String, CodingKey { case name, source, sourceID, ean = "EAN", platform, cover, region }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            sourceID = try Self.decodeString(container, key: .sourceID)
            ean = try Self.decodeString(container, key: .ean)
            platform = try container.decodeIfPresent(String.self, forKey: .platform)
            cover = try container.decodeIfPresent(URL.self, forKey: .cover)
            region = try Self.decodeString(container, key: .region)
        }

        private static func decodeString(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> String? {
            if let value = try? container.decode(String.self, forKey: key) { return value }
            if let value = try? container.decode(Int.self, forKey: key) { return String(value) }
            return nil
        }
    }

    private var apiKey: String =  "3rMe42DBVCyW1WhX5YIXrQuiHzfev3NhybdUzOve6WlhtROetkcmdHkDa35PpZaWPL74Z9gwE5nkDIz1JVP5rYZ1GErZtY18ZYBv"
    private let baseURL = URL(string: "https://levelcomplete.de/api/v3a/")!

    init(apiKey: String? = nil) {
        self.apiKey = apiKey ?? "3rMe42DBVCyW1WhX5YIXrQuiHzfev3NhybdUzOve6WlhtROetkcmdHkDa35PpZaWPL74Z9gwE5nkDIz1JVP5rYZ1GErZtY18ZYBv"
    }

    func product(for barcode: Barcode) async throws -> ProductMetadata? {
        guard !apiKey.isEmpty else { throw ProductLookupError.missingAPIKey }
        let lookupValues = barcode.value.hasPrefix("0") ? [barcode.value, String(barcode.value.dropFirst())] : [barcode.value]
        var game: Game?
        for lookupValue in lookupValues {
            let endpoint = baseURL.appending(path: "ean").appending(path: lookupValue)
            var request = URLRequest(url: endpoint, timeoutInterval: 15)
            request.setValue(apiKey, forHTTPHeaderField: "Apikey")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProductLookupError.invalidResponse }
            if http.statusCode == 401 || http.statusCode == 403 { throw ProductLookupError.unauthorized }
            if http.statusCode == 429 { throw ProductLookupError.rateLimited }
            guard (200..<300).contains(http.statusCode) else { throw ProductLookupError.serviceUnavailable }
            let games = try JSONDecoder().decode([Game].self, from: data)
            if let first = games.first { game = first; break }
        }
        guard let game, let title = game.name, !title.isEmpty else { return nil }
        var fields: [String: String] = [:]
        if let platform = game.platform, !platform.isEmpty { fields["platform"] = platform }
        if let region = game.region, !region.isEmpty { fields["region"] = region }
        if let source = game.source, !source.isEmpty { fields["source"] = source }
        if let sourceID = game.sourceID, !sourceID.isEmpty { fields["sourceID"] = sourceID }
        return ProductMetadata(title: title, brand: "", variant: game.platform ?? "", quantity: nil, categories: ["Game"], country: game.region, imageURL: game.cover, extraFields: fields)
    }
}

struct GameUPCProvider: ProductMetadataProvider {
    private struct Response: Decodable { let status: String?; let name: String?; let bggInfo: [BggInfo]?; enum CodingKeys: String, CodingKey { case status, name, bggInfo = "bgg_info" } }
    private struct BggInfo: Decodable { let id: Int?; let name: String?; let thumbnailURL: URL?; let imageURL: URL?; let confidence: Int?; enum CodingKeys: String, CodingKey { case id, name, thumbnailURL = "thumbnail_url", imageURL = "image_url", confidence } }
    func product(for barcode: Barcode) async throws -> ProductMetadata? {
        let values = barcode.value.hasPrefix("0") ? [barcode.value, String(barcode.value.dropFirst())] : [barcode.value]
        for value in values {
            let url = URL(string: "https://api.gameupc.com/test/upc/\(value)")!
            var request = URLRequest(url: url, timeoutInterval: 15); request.setValue("CollectionManager/1.0 (board-game lookup)", forHTTPHeaderField: "User-Agent"); request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProductLookupError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw ProductLookupError.serviceUnavailable }
            let result = try JSONDecoder().decode(Response.self, from: data)
            guard let info = result.bggInfo?.sorted(by: { ($0.confidence ?? 0) > ($1.confidence ?? 0) }).first, let title = info.name ?? result.name, !title.isEmpty else { continue }
            var fields: [String: String] = [:]; if let id = info.id { fields["bggID"] = String(id) }; if let confidence = info.confidence { fields["confidence"] = String(confidence) }; fields["source"] = "BoardGameGeek"
            return ProductMetadata(title: title, brand: "", variant: "", quantity: nil, categories: ["Board Game"], country: nil, imageURL: info.imageURL ?? info.thumbnailURL, extraFields: fields)
        }
        return nil
    }
}

struct OpenFactsProvider: ProductMetadataProvider {
    private struct Response: Decodable { let status: Int; let product: Product? }
    private struct Product: Decodable { let productName: String?; let brands: String?; let quantity: String?; let categories: String?; let countries: String?; let imageURL: String?; enum CodingKeys: String, CodingKey { case productName = "product_name", brands, quantity, categories, countries, imageURL = "image_url" } }
    let host: String
    func product(for barcode: Barcode) async throws -> ProductMetadata? {
        let url = URL(string: "https://\(host)/api/v2/product/\(barcode.value).json")!
        var request = URLRequest(url: url, timeoutInterval: 15); request.setValue("CollectionManager/1.0 (iOS)", forHTTPHeaderField: "User-Agent"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request); guard let http = response as? HTTPURLResponse else { throw ProductLookupError.invalidResponse }; if http.statusCode == 429 { throw ProductLookupError.rateLimited }; guard (200..<300).contains(http.statusCode) else { throw ProductLookupError.serviceUnavailable }
        let result = try JSONDecoder().decode(Response.self, from: data); guard result.status == 1, let product = result.product, let title = product.productName, !title.isEmpty else { return nil }
        var fields: [String: String] = [:]; if let categories = product.categories, !categories.isEmpty { fields["categories"] = categories }; if let country = product.countries, !country.isEmpty { fields["country"] = country }
        return ProductMetadata(title: title, brand: product.brands ?? "", variant: product.quantity ?? "", quantity: product.quantity, categories: product.categories?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [], country: product.countries, imageURL: product.imageURL.flatMap(URL.init(string:)), extraFields: fields)
    }
}

struct OpenLibraryProvider: ProductMetadataProvider {
    private struct Book: Decodable { let title: String?; let authors: [Author]?; let publishers: [Publisher]?; let publishDate: String?; let numberOfPages: Int?; let cover: Cover?; enum CodingKeys: String, CodingKey { case title, authors, publishers, publishDate = "publish_date", numberOfPages = "number_of_pages", cover } }
    private struct Author: Decodable { let name: String? }; private struct Publisher: Decodable { let name: String? }; private struct Cover: Decodable { let medium: URL? }
    func product(for barcode: Barcode) async throws -> ProductMetadata? {
        var components = URLComponents(string: "https://openlibrary.org/api/books")!; components.queryItems = [URLQueryItem(name: "bibkeys", value: "ISBN:\(barcode.value)"), URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "jscmd", value: "data")]
        var request = URLRequest(url: components.url!, timeoutInterval: 15); request.setValue("CollectionManager/1.0 (contact via app settings)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request); guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProductLookupError.serviceUnavailable }
        let books = try JSONDecoder().decode([String: Book].self, from: data); guard let book = books.values.first, let title = book.title, !title.isEmpty else { return nil }
        let authors = book.authors?.compactMap(\.name).joined(separator: ", ") ?? ""; let publisher = book.publishers?.compactMap(\.name).joined(separator: ", ") ?? ""; var fields: [String: String] = [:]; if !authors.isEmpty { fields["authors"] = authors }; if !publisher.isEmpty { fields["publisher"] = publisher }; if let date = book.publishDate { fields["publishedDate"] = date }; if let pages = book.numberOfPages { fields["pages"] = String(pages) }
        return ProductMetadata(title: title, brand: authors, variant: publisher, quantity: nil, categories: ["Book"], country: nil, imageURL: book.cover?.medium, extraFields: fields)
    }
}

struct MusicBrainzProvider: ProductMetadataProvider {
    private struct Response: Decodable { let releases: [Release] }
    private struct Release: Decodable { let title: String?; let date: String?; let country: String?; let barcode: String?; let artistCredit: [ArtistCredit]?; enum CodingKeys: String, CodingKey { case title, date, country, barcode, artistCredit = "artist-credit" } }
    private struct ArtistCredit: Decodable { let name: String?; let artist: Artist? }; private struct Artist: Decodable { let name: String? }
    func product(for barcode: Barcode) async throws -> ProductMetadata? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!; components.queryItems = [URLQueryItem(name: "query", value: "barcode:\(barcode.value)"), URLQueryItem(name: "fmt", value: "json"), URLQueryItem(name: "limit", value: "1")]
        var request = URLRequest(url: components.url!, timeoutInterval: 15); request.setValue("CollectionManager/1.0 (contact via app settings)", forHTTPHeaderField: "User-Agent"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request); guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProductLookupError.serviceUnavailable }; let result = try JSONDecoder().decode(Response.self, from: data); guard let release = result.releases.first, let title = release.title, !title.isEmpty else { return nil }
        let artist = release.artistCredit?.compactMap { $0.name ?? $0.artist?.name }.joined(separator: ", ") ?? ""; var fields: [String: String] = [:]; if !artist.isEmpty { fields["artist"] = artist }; if let date = release.date { fields["releaseDate"] = date }; if let country = release.country { fields["country"] = country }; fields["format"] = "Music release"
        return ProductMetadata(title: title, brand: artist, variant: "", quantity: nil, categories: ["Music"], country: release.country, imageURL: nil, extraFields: fields)
    }
}

enum RecognitionError: LocalizedError { case invalidImage; var errorDescription: String? { "The image could not be analyzed." } }
