import Foundation
import XCTest
@testable import CollectionManager

final class ProviderCredentialTests: XCTestCase {
    private let barcode = Barcode(rawValue: "036000291452")!

    func testCredentialRejectsHeaderControlCharactersBeforeNetworking() async throws {
        for value in ["key\r\nInjected: value", "key with space", "key\u{0}suffix"] {
            let provider = GamesEANProvider(apiKey: value, transport: { _ in
                XCTFail("Invalid credentials must never enter HTTP headers")
                throw URLError(.badURL)
            })
            do { _ = try await provider.product(for: barcode); XCTFail("Expected invalid key") }
            catch let error as ProductLookupError {
                guard case .invalidAPIKey = error else { return XCTFail("Wrong error") }
            }
        }
    }

    func testMissingCredentialNeverSendsRequest() async throws {
        let provider = GamesEANProvider(apiKey: " \n ", transport: { _ in
            XCTFail("A request must not be sent without a user credential")
            throw URLError(.badURL)
        })
        do { _ = try await provider.product(for: barcode); XCTFail("Expected missing key") }
        catch let error as ProductLookupError {
            guard case .missingAPIKey = error else { return XCTFail("Wrong error") }
        }
    }

    func testUnauthorizedAndRateLimitedResponsesAreActionable() async throws {
        for status in [401, 403, 429] {
            let provider = GamesEANProvider(apiKey: "synthetic-user-key", transport: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Apikey"), "synthetic-user-key")
                XCTAssertFalse(request.url!.absoluteString.contains("synthetic-user-key"))
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            do { _ = try await provider.product(for: barcode); XCTFail("Expected HTTP failure") }
            catch let error as ProductLookupError {
                switch (status, error) {
                case (401, .unauthorized), (403, .unauthorized), (429, .rateLimited): break
                default: XCTFail("Wrong HTTP error mapping")
                }
                XCTAssertFalse(error.localizedDescription.contains("synthetic-user-key"))
            }
        }
    }

    func testMalformedResponseDoesNotExposeResponseBody() async throws {
        let provider = GamesEANProvider(apiKey: "synthetic-user-key", transport: { request in
            (Data("private response body".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await provider.product(for: barcode); XCTFail("Expected decoding failure") }
        catch let error as ProductLookupError {
            guard case .invalidResponse = error else { return XCTFail("Wrong error") }
            XCTAssertFalse(error.localizedDescription.contains("private response body"))
        }
    }

    func testNetworkFailureIsSanitized() async throws {
        let provider = GamesEANProvider(apiKey: "synthetic-user-key", transport: { _ in
            throw URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "synthetic-user-key"])
        })
        do { _ = try await provider.product(for: barcode); XCTFail("Expected network failure") }
        catch let error as ProductLookupError {
            guard case .network(.notConnectedToInternet) = error else { return XCTFail("Wrong error") }
            XCTAssertFalse(error.localizedDescription.contains("synthetic-user-key"))
        }
    }

    func testValidResponseMapsGameMetadata() async throws {
        let provider = GamesEANProvider(apiKey: "synthetic-user-key", transport: { request in
            (Data(#"[{"name":"Example game","platform":"Console","sourceID":123,"region":"EU"}]"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let product = try await provider.product(for: barcode)
        XCTAssertEqual(product?.title, "Example game")
        XCTAssertEqual(product?.variant, "Console")
        XCTAssertEqual(product?.extraFields["sourceID"], "123")
    }
}
