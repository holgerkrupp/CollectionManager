import Foundation
import Vision
import ImageIO
import Security
import UniformTypeIdentifiers

struct OCRResult: Sendable { var text: String; var lines: [String] }

struct ImageProcessor: Sendable {
    nonisolated static let maximumSharedImageBytes = 750_000

    static func preparedData(_ data: Data, maximumPixelSize: Int = 1_600, maximumByteCount: Int = maximumSharedImageBytes) async -> Data {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
            var smallestResult = data
            let pixelSizes = [maximumPixelSize, 1_280, 1_024, 800, 640, 480, 320].filter { $0 <= maximumPixelSize }
            let qualities = [0.78, 0.65, 0.52, 0.42, 0.32]
            for pixelSize in pixelSizes {
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelSize
                ] as CFDictionary) else { continue }
                for quality in qualities {
                    guard let output = CFDataCreateMutable(nil, 0),
                          let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else { continue }
                    let candidate = output as Data
                    if candidate.count < smallestResult.count { smallestResult = candidate }
                    if candidate.count <= maximumByteCount { return candidate }
                }
            }
            return smallestResult
        }.value
    }
}

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
protocol ProductNameSearchProvider: Sendable { func products(matching query: String) async throws -> [ProductMetadata] }
struct ProductMetadata: Sendable { var title: String; var brand: String; var variant: String; var quantity: String?; var categories: [String]; var country: String?; var imageURL: URL?; var barcode: Barcode? = nil; var extraFields: [String: String] = [:]; var sourceSnapshot: ProductSourceSnapshot? = nil }

struct FirstMatchProductProvider: ProductMetadataProvider {
    let providers: [any ProductMetadataProvider]
    func product(for barcode: Barcode) async throws -> ProductMetadata? {
        var lastError: Error?
        for provider in providers {
            do { if let product = try await provider.product(for: barcode) { return product } }
            catch { lastError = error }
        }
        if let lastError { throw lastError }
        return nil
    }
}

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

private struct OpenFoodFactsProduct: Codable {
    let code: String?
    let productName: String?
    let genericName: String?
    let brands: String?
    let quantity: String?
    let categories: String?
    let countries: String?
    let imageURL: String?
    let alcohol: Double?
    enum CodingKeys: String, CodingKey { case code, productName = "product_name", genericName = "generic_name", brands, quantity, categories, countries, imageURL = "image_url", alcohol = "alcohol_100g" }
}

struct OpenFoodFactsProvider: ProductMetadataProvider {
    private struct Response: Decodable { let status: Int; let product: OpenFoodFactsProduct? }
    func product(for barcode: Barcode) async throws -> ProductMetadata? {
        if let cached = await ProductMetadataCache.shared.value(for: barcode.value) { return cached }
        var components = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode.value).json")!
        components.queryItems = [URLQueryItem(name: "fields", value: "product_name,brands,quantity,categories,countries,image_url,alcohol_100g")]
        let endpoint = components.url!
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: 15)
                request.setValue("CollectionManager/1.0 (iOS; contact via app settings)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ProductLookupError.invalidResponse }
                if http.statusCode == 429 { throw ProductLookupError.rateLimited }
                guard (200..<300).contains(http.statusCode) else { throw ProductLookupError.serviceUnavailable }
                let result = try JSONDecoder().decode(Response.self, from: data)
                guard result.status == 1, let product = result.product, let title = product.productName, !title.isEmpty else { return nil }
                var metadata = FoodProductMapper.metadata(barcode: barcode.value, title: title, brand: product.brands, quantity: product.quantity, categories: product.categories, country: product.countries, imageURL: product.imageURL, alcohol: product.alcohol)
                metadata.barcode = barcode
                if let genericName = product.genericName, !genericName.isEmpty { metadata.extraFields["genericName"] = genericName }
                metadata.sourceSnapshot = ProductSourceSnapshot(provider: "openFoodFacts", barcode: barcode.value, payloadData: data, mappedFields: metadata.snapshotFields)
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

struct OpenFoodFactsNameSearchProvider: ProductNameSearchProvider {
    private struct Response: Decodable { let products: [OpenFoodFactsProduct] }
    private static let returnedFields = "code,product_name,generic_name,brands,quantity,categories,countries,image_url,alcohol_100g"

    func products(matching rawQuery: String) async throws -> [ProductMetadata] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let curatedMatches = CuratedSpiritCatalog.products(matching: query)
        if curatedMatches.contains(where: { Self.searchKey([$0.brand, $0.extraFields["expression"] ?? ""].joined(separator: " ")) == Self.searchKey(query) }) {
            return curatedMatches
        }
        var components = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "fields", value: Self.returnedFields)
        ]
        guard let endpoint = components.url else { throw ProductLookupError.invalidResponse }

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: 20)
                request.setValue("CollectionManager/1.0 (iOS; contact via app settings)", forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ProductLookupError.invalidResponse }
                if http.statusCode == 429 { throw ProductLookupError.rateLimited }
                guard (200..<300).contains(http.statusCode) else { throw ProductLookupError.serviceUnavailable }
                let result = try JSONDecoder().decode(Response.self, from: data)
                let remoteMatches = rankedProducts(result.products, query: query)
                return Self.merging(curatedMatches, with: remoteMatches)
            } catch let error as ProductLookupError {
                lastError = error
                if case .rateLimited = error { break }
            } catch let error as URLError {
                lastError = ProductLookupError.network(error.code)
            } catch {
                lastError = ProductLookupError.invalidResponse
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(400 * (attempt + 1))) }
        }
        if !curatedMatches.isEmpty { return curatedMatches }
        throw lastError ?? ProductLookupError.serviceUnavailable
    }

    private func rankedProducts(_ products: [OpenFoodFactsProduct], query: String) -> [ProductMetadata] {
        let queryKey = Self.searchKey(query)
        let queryTokens = Set(queryKey.split(separator: " ").map(String.init))
        var seen: Set<String> = []
        return products.compactMap { product -> (Int, ProductMetadata)? in
            guard let rawTitle = product.productName?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty else { return nil }
            let barcode = product.code.flatMap { Barcode(rawValue: $0) }
            let uniqueKey = barcode?.value ?? Self.searchKey([rawTitle, product.brands ?? "", product.quantity ?? ""].joined(separator: "|"))
            guard seen.insert(uniqueKey).inserted else { return nil }
            let candidateKey = Self.searchKey([rawTitle, product.brands ?? "", product.genericName ?? ""].joined(separator: " "))
            let candidateTokens = Set(candidateKey.split(separator: " ").map(String.init))
            let matchingTokenCount = queryTokens.intersection(candidateTokens).count
            guard matchingTokenCount > 0 else { return nil }
            var score = matchingTokenCount * 20
            if candidateKey == queryKey { score += 100 }
            else if candidateKey.contains(queryKey) { score += 60 }
            if queryTokens.isSubset(of: candidateTokens) { score += 40 }
            if barcode != nil { score += 2 }

            let code = barcode?.value ?? product.code ?? ""
            var metadata = FoodProductMapper.metadata(barcode: code, title: rawTitle, brand: product.brands, quantity: product.quantity, categories: product.categories, country: product.countries, imageURL: product.imageURL, alcohol: product.alcohol)
            metadata.barcode = barcode
            if let genericName = product.genericName, !genericName.isEmpty { metadata.extraFields["genericName"] = genericName }
            if let payload = try? JSONEncoder().encode(product) {
                metadata.sourceSnapshot = ProductSourceSnapshot(provider: "openFoodFactsNameSearch", barcode: code, payloadData: payload, mappedFields: metadata.snapshotFields)
            }
            return (score, metadata)
        }
        .sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            return lhs.1.title.localizedStandardCompare(rhs.1.title) == .orderedAscending
        }
        .prefix(10)
        .map(\.1)
    }

    private static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func merging(_ preferred: [ProductMetadata], with other: [ProductMetadata]) -> [ProductMetadata] {
        var seen: Set<String> = []
        return (preferred + other).filter { product in
            let key = product.barcode?.value ?? searchKey([product.brand, product.title, product.variant].joined(separator: "|"))
            return seen.insert(key).inserted
        }
    }
}

private extension ProductMetadata {
    var snapshotFields: [String: String] {
        var fields = extraFields
        fields["title"] = title
        if !brand.isEmpty { fields["brand"] = brand }
        if !variant.isEmpty { fields["variant"] = variant }
        if let quantity, !quantity.isEmpty { fields["quantity"] = quantity }
        if !categories.isEmpty { fields["categories"] = categories.joined(separator: ", ") }
        if let country, !country.isEmpty { fields["country"] = country }
        if let imageURL { fields["imageURL"] = imageURL.absoluteString }
        if let barcode { fields["barcode"] = barcode.value }
        return fields
    }
}

enum FoodProductMapper {
    private struct CatalogCorrection {
        let expression: String?
    }

    // Open Food Facts entries occasionally omit a bottle's named expression even
    // when the GTIN identifies it unambiguously. Keep those verified corrections
    // narrow and barcode-specific so they cannot affect another release.
    private static let catalogCorrections: [String: CatalogCorrection] = [
        "5010314302863": CatalogCorrection(expression: "Double Cask")
    ]
    private static let spiritTerms = ["whisky", "whiskey", "scotch", "bourbon", "rum", "gin", "vodka", "tequila", "brandy", "cognac", "liqueur", "liquor", "spirit"]

    static func metadata(barcode: String, title rawTitle: String, brand rawBrand: String?, quantity rawQuantity: String?, categories rawCategories: String?, country: String?, imageURL: String?, alcohol: Double?) -> ProductMetadata {
        let categories = rawCategories?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let searchable = ([rawTitle] + categories).joined(separator: " ").lowercased()
        let isSpirit = spiritTerms.contains { searchable.contains($0) }
        let brand = normalizedBrand(rawBrand)
        let packageSize = normalizedPackageSize(rawQuantity, isSpirit: isSpirit)
        let correction = catalogCorrections[barcode]

        guard isSpirit else {
            var fields: [String: String] = [:]
            if let packageSize { fields["packageSize"] = packageSize }
            return ProductMetadata(title: cleaned(rawTitle), brand: brand, variant: packageSize ?? "", quantity: packageSize, categories: categories, country: country, imageURL: imageURL.flatMap(URL.init(string:)), extraFields: fields)
        }

        let age = firstMatch(in: rawTitle, pattern: #"\b(\d{1,3})\s*(?:[- ]?ročn[aá]|y\.?\s*o\.?|years?\s*old|ans?|a(?:ñ|n)os?|jahre?)\b"#).flatMap { match -> String? in
            firstMatch(in: match, pattern: #"\d{1,3}"#).map { "\($0) Year Old" }
        }
        let strength = firstMatch(in: rawTitle, pattern: #"\b\d{1,2}(?:[.,]\d+)?\s*%"#)?.replacingOccurrences(of: " ", with: "") ?? formattedStrength(alcohol)
        var name = rawTitle
        if let age { name = removingMatch(from: name, pattern: #"(?i)\b\d{1,3}\s*(?:[- ]?ročn[aá]|y\.?\s*o\.?|years?\s*old|ans?|a(?:ñ|n)os?|jahre?)\b"#) }
        if strength != nil { name = removingMatch(from: name, pattern: #"\b\d{1,2}(?:[.,]\d+)?\s*%"#) }
        if !brand.isEmpty {
            let escapedBrand = NSRegularExpression.escapedPattern(for: brand)
            name = removingMatch(from: name, pattern: "(?i)\\b(?:the\\s+)?\(escapedBrand)\\b")
        }
        name = cleaned(name)
        name = removingGenericSpiritPrefix(from: name)
        let spiritType = displaySpiritType(in: searchable)
        let inferredExpression: String?
        if correction?.expression == nil, !name.isEmpty, !spiritTerms.contains(name.lowercased()) {
            inferredExpression = name
            name = [brand, spiritType].filter { !$0.isEmpty }.joined(separator: " ")
        } else {
            inferredExpression = nil
        }
        if name.isEmpty || spiritTerms.contains(name.lowercased()) {
            name = [brand, spiritType].filter { !$0.isEmpty }.joined(separator: " ")
        }

        let expression = correction?.expression ?? inferredExpression
        let variantParts = [expression, age, strength, packageSize].compactMap { $0 }.uniquedCaseInsensitive()
        var fields: [String: String] = [:]
        if let expression { fields["expression"] = expression }
        if let age { fields["age"] = age }
        if let strength { fields["alcoholStrength"] = strength }
        if let packageSize { fields["packageSize"] = packageSize }
        return ProductMetadata(title: name, brand: brand, variant: variantParts.joined(separator: " · "), quantity: packageSize, categories: categories, country: country, imageURL: imageURL.flatMap(URL.init(string:)), extraFields: fields)
    }

    private static func normalizedBrand(_ value: String?) -> String {
        let value = cleaned(value ?? "")
        guard value == value.uppercased(), value.rangeOfCharacter(from: .letters) != nil else { return value }
        return value.localizedCapitalized
    }

    private static func normalizedPackageSize(_ value: String?, isSpirit: Bool) -> String? {
        guard var value = value.map(cleaned), !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: #"(?i)(\d)\s*(ml|cl|l|g|kg)\b"#, with: "$1 $2", options: .regularExpression)
        if isSpirit, value.range(of: #"(?i)^\d+(?:[.,]\d+)?\s*g$"#, options: .regularExpression) != nil {
            value = value.replacingOccurrences(of: #"(?i)g$"#, with: "ml", options: .regularExpression)
        }
        return value.replacingOccurrences(of: "ML", with: "ml").replacingOccurrences(of: "Ml", with: "ml")
    }

    private static func formattedStrength(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return value.rounded() == value ? "\(Int(value))%" : "\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    private static func displaySpiritType(in searchable: String) -> String {
        if searchable.contains("whiskey") { return "Whiskey" }
        if searchable.contains("whisky") || searchable.contains("scotch") { return "Whisky" }
        if searchable.contains("bourbon") { return "Bourbon" }
        if searchable.contains("cognac") { return "Cognac" }
        if searchable.contains("brandy") { return "Brandy" }
        if searchable.contains("tequila") { return "Tequila" }
        if searchable.contains("vodka") { return "Vodka" }
        if searchable.contains("rum") { return "Rum" }
        if searchable.contains("gin") { return "Gin" }
        if searchable.contains("liqueur") { return "Liqueur" }
        return "Spirit"
    }

    private static func firstMatch(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let range = Range(match.range, in: value) else { return nil }
        return String(value[range])
    }

    private static func removingMatch(from value: String, pattern: String) -> String {
        value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }

    private static func cleaned(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s*[-–—|]\s*"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingGenericSpiritPrefix(from value: String) -> String {
        let result = value.replacingOccurrences(of: #"(?i)^(?:whisky|whiskey|scotch|spirit)\s+(?=\S)"#, with: "", options: .regularExpression)
        return cleaned(result)
    }
}

private enum CuratedSpiritCatalog {
    private struct Entry {
        let searchName: String
        let title: String
        let brand: String
        let expression: String
        let barcode: String
        let country: String
        let categories: [String]
        let fields: [String: String]
    }

    // Some spirit releases are absent from general food databases. These narrow,
    // source-attributed entries keep verified details available without pretending
    // that a fuzzy name match identifies an arbitrary bottle.
    private static let entries: [Entry] = [
        Entry(
            searchName: "Talisker Dark Storm",
            title: "Talisker Whisky",
            brand: "Talisker",
            expression: "Dark Storm",
            barcode: "5000281033631",
            country: "Scotland",
            categories: ["Single Malt Scotch Whisky", "Travel Retail Exclusive"],
            fields: [
                "expression": "Dark Storm",
                "alcoholStrength": "45.8%",
                "packageSize": "1 L",
                "region": "Islands",
                "cask": "Heavily charred oak casks",
                "ageStatement": "No age statement",
                "sourceURL": "https://www.malts.com/en/products/talisker-dark-storm-single-malt-whisky-1l"
            ]
        )
    ]

    static func products(matching query: String) -> [ProductMetadata] {
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return [] }
        return entries.compactMap { entry in
            let entryTokens = tokens(entry.searchName)
            guard queryTokens.isSubset(of: entryTokens) || entryTokens.isSubset(of: queryTokens) else { return nil }
            let barcode = Barcode(rawValue: entry.barcode)
            let variant = [entry.expression, entry.fields["alcoholStrength"], entry.fields["packageSize"]].compactMap { $0 }.joined(separator: " · ")
            var product = ProductMetadata(title: entry.title, brand: entry.brand, variant: variant, quantity: entry.fields["packageSize"], categories: entry.categories, country: entry.country, imageURL: nil, barcode: barcode, extraFields: entry.fields)
            let payload: [String: Any] = [
                "search_name": entry.searchName,
                "title": entry.title,
                "brand": entry.brand,
                "barcode": entry.barcode,
                "country": entry.country,
                "categories": entry.categories,
                "verified_fields": entry.fields
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                product.sourceSnapshot = ProductSourceSnapshot(provider: "curatedSpiritCatalog", barcode: entry.barcode, payloadData: data, mappedFields: product.snapshotFields)
            }
            return product
        }
    }

    private static func tokens(_ value: String) -> Set<String> {
        Set(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init))
    }
}

private extension Array where Element == String {
    func uniquedCaseInsensitive() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0.lowercased()).inserted }
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

    private var apiKey: String = "3rMe42DBVCyW1WhX5YIXrQuiHzfev3NhybdUzOve6WlhtROetkcmdHkDa35PpZaWPL74Z9gwE5nkDIz1JVP5rYZ1GErZtY18ZYBv"
    private let baseURL = URL(string: "https://levelcomplete.de/api/v3a/")!

    init(apiKey: String? = nil) {
        let configuredKey = GamesEANAPIKeyStore.load()
        self.apiKey = apiKey ?? (configuredKey.isEmpty ? "3rMe42DBVCyW1WhX5YIXrQuiHzfev3NhybdUzOve6WlhtROetkcmdHkDa35PpZaWPL74Z9gwE5nkDIz1JVP5rYZ1GErZtY18ZYBv" : configuredKey)
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
            let url = URL(string: "https://api.gameupc.com/upc/\(value)")!
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
    private struct DirectBook: Decodable { let title: String?; let authors: [Author]?; let publishers: [Publisher]?; let publishDate: String?; let numberOfPages: Int?; let covers: [Int]?; enum CodingKeys: String, CodingKey { case title, authors, publishers, publishDate = "publish_date", numberOfPages = "number_of_pages", covers } }
    func product(for barcode: Barcode) async throws -> ProductMetadata? {
        var components = URLComponents(string: "https://openlibrary.org/api/books")!; components.queryItems = [URLQueryItem(name: "bibkeys", value: "ISBN:\(barcode.value)"), URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "jscmd", value: "data")]
        var request = URLRequest(url: components.url!, timeoutInterval: 15); request.setValue("CollectionManager/1.0 (contact via app settings)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request); guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProductLookupError.serviceUnavailable }
        if let books = try? JSONDecoder().decode([String: Book].self, from: data), let book = books.values.first, let title = book.title, !title.isEmpty {
            return Self.metadata(title: title, authors: book.authors, publishers: book.publishers, date: book.publishDate, pages: book.numberOfPages, imageURL: book.cover?.medium)
        }

        let directURL = URL(string: "https://openlibrary.org/isbn/\(barcode.value).json")!
        var directRequest = URLRequest(url: directURL, timeoutInterval: 15); directRequest.setValue("CollectionManager/1.0 (contact via app settings)", forHTTPHeaderField: "User-Agent")
        let (directData, directResponse) = try await URLSession.shared.data(for: directRequest)
        guard (directResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let book = try JSONDecoder().decode(DirectBook.self, from: directData); guard let title = book.title, !title.isEmpty else { return nil }
        let imageURL = book.covers?.first.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-M.jpg") }
        return Self.metadata(title: title, authors: book.authors, publishers: book.publishers, date: book.publishDate, pages: book.numberOfPages, imageURL: imageURL)
    }

    private static func metadata(title: String, authors: [Author]?, publishers: [Publisher]?, date: String?, pages: Int?, imageURL: URL?) -> ProductMetadata {
        let authorNames = authors?.compactMap(\.name).joined(separator: ", ") ?? ""; let publisherNames = publishers?.compactMap(\.name).joined(separator: ", ") ?? ""; var fields: [String: String] = [:]; if !authorNames.isEmpty { fields["authors"] = authorNames }; if !publisherNames.isEmpty { fields["publisher"] = publisherNames }; if let date { fields["publishedDate"] = date }; if let pages { fields["pages"] = String(pages) }
        return ProductMetadata(title: title, brand: authorNames, variant: publisherNames, quantity: nil, categories: ["Book"], country: nil, imageURL: imageURL, extraFields: fields)
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
