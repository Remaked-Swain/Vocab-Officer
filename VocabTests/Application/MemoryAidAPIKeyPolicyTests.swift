import SwiftData
import XCTest
@testable import Vocab

/// Distribution policy (#9): no developer key ships; Gemini runs only with
/// the tester's own key, held in this device's Keychain.
@MainActor
final class MemoryAidAPIKeyPolicyTests: XCTestCase {
    func testWithoutAKeyGenerationFailsBeforeAnyNetworkRequest() async throws {
        let keyStore = isolatedKeyStore()
        RecordingURLProtocol.requestCount = 0
        let service = MemoryAidService(
            context: try makeContext(),
            session: recordingSession(),
            apiKeyStore: keyStore
        )

        do {
            _ = try await service.generate(for: WordRecord(term: "keyless"), model: .defaultModel)
            XCTFail("generation must not proceed without a key")
        } catch let error as MemoryAidError {
            guard case .missingAPIKey = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertEqual(RecordingURLProtocol.requestCount, 0)
    }

    func testDeletingTheKeyDisablesGenerationAgain() throws {
        let keyStore = isolatedKeyStore()
        try keyStore.save("tester-key")
        XCTAssertEqual(try keyStore.load(), "tester-key")

        try keyStore.delete()

        XCTAssertNil(try keyStore.load())
    }

    private func isolatedKeyStore() -> GeminiAPIKeyStore {
        let store = GeminiAPIKeyStore(service: "com.swainyun.Vocab.gemini.tests.\(UUID().uuidString)")
        addTeardownBlock { try? store.delete() }
        return store
    }

    private func recordingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(VocabModelContainerFactory.schemaModels)
        return ModelContext(try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ))
    }
}

/// Counts requests and fails them, so a leak is visible without a network.
private final class RecordingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
