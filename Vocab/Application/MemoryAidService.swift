import Foundation
import Security
import SwiftData

enum MemoryAidModel: String, CaseIterable, Identifiable {
    case gemini35Flash = "gemini-3.5-flash"
    case gemini31FlashLite = "gemini-3.1-flash-lite"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini35Flash:
            "Gemini 3.5 Flash"
        case .gemini31FlashLite:
            "Gemini 3.1 Flash-Lite"
        }
    }

    var summary: String {
        switch self {
        case .gemini35Flash:
            "속도와 품질 균형"
        case .gemini31FlashLite:
            "더 가볍고 저렴한 호출"
        }
    }
}

struct WordMemoryAid: Equatable {
    let markdown: String
    let generatedAt: Date
    let source: Source

    enum Source: Equatable {
        case cached
        case generated
    }
}

enum MemoryAidError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case emptyResponse
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "설정에서 Gemini API 키를 먼저 입력하세요."
        case .invalidResponse:
            "암기 도움 응답 형식을 해석하지 못했습니다."
        case .emptyResponse:
            "암기 도움 내용을 받지 못했습니다."
        case .providerError(let message):
            message
        }
    }
}

struct MemoryAidPromptBuilder {
    static let version = 2

    static func build(for word: WordRecord) -> String {
        let meanings = word.meanings.map(\.text).joined(separator: ", ")

        return """
        You are helping a Korean learner memorize one English vocabulary item for a public-service exam.

        Word: \(word.term)
        Meanings: \(meanings)

        Write concise study help in Korean using Markdown.
        Follow these rules:
        - Be accurate. If etymology or a comparison is uncertain, say that it is uncertain instead of fabricating.
        - Keep the whole answer under 220 Korean characters if possible.
        - Prefer practical memorization help over encyclopedia-style explanation.
        - Use exactly these sections:
          ## 한줄 기억
          ## 형태/어원
          ## 연상 포인트
          ## 예문
          ## 비교
        - In 예문, provide one short English sentence and one Korean gloss.
        - In 비교, prefer similar/confusable words or antonyms only when actually useful.
        """
    }

    static func repair(for word: WordRecord, invalidOutput: String) -> String {
        """
        The previous answer did not follow the required format or quality rules.

        Word: \(word.term)
        Meanings: \(word.meanings.map(\.text).joined(separator: ", "))

        Invalid answer:
        \(invalidOutput)

        Rewrite from scratch.
        Requirements:
        - Output in Korean Markdown only.
        - Use all five headings exactly once:
          ## 한줄 기억
          ## 형태/어원
          ## 연상 포인트
          ## 예문
          ## 비교
        - Do not invent uncertain etymology or comparisons.
        - Keep each section to 1-2 short lines.
        - In 예문, include one English sentence and one Korean gloss.
        """
    }
}

enum MemoryAidQualityGate {
    private static let requiredSections = [
        "## 한줄 기억",
        "## 형태/어원",
        "## 연상 포인트",
        "## 예문",
        "## 비교"
    ]

    static func validate(_ markdown: String) -> Bool {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard requiredSections.allSatisfy(trimmed.contains) else { return false }
        guard requiredSections.allSatisfy({ heading in trimmed.components(separatedBy: heading).count == 2 }) else { return false }
        guard trimmed.count <= 1_400 else { return false }
        return true
    }

    static func contentSignature(for word: WordRecord) -> String {
        let meanings = word.meanings
            .map(\.text)
            .sorted()
            .joined(separator: "|")
        return "\(word.normalizedTerm)|\(meanings)"
    }
}

@MainActor
final class MemoryAidService {
    private let context: ModelContext
    private let session: URLSession
    private let apiKeyStore: GeminiAPIKeyStore

    init(
        context: ModelContext,
        session: URLSession = .shared,
        apiKeyStore: GeminiAPIKeyStore = .shared
    ) {
        self.context = context
        self.session = session
        self.apiKeyStore = apiKeyStore
    }

    func generate(for word: WordRecord, model: MemoryAidModel, forceRefresh: Bool = false) async throws -> WordMemoryAid {
        guard let apiKey = try apiKeyStore.load(), !apiKey.isEmpty else {
            throw MemoryAidError.missingAPIKey
        }

        let signature = MemoryAidQualityGate.contentSignature(for: word)
        if !forceRefresh, let cached = try fetchCache(wordID: word.id, model: model, signature: signature) {
            return WordMemoryAid(markdown: cached.markdown, generatedAt: cached.generatedAt, source: .cached)
        }

        let generatedText = try await requestValidatedMarkdown(
            using: apiKey,
            model: model,
            prompts: [
                MemoryAidPromptBuilder.build(for: word)
            ],
            word: word
        )
        let cache = try upsertCache(
            wordID: word.id,
            model: model,
            signature: signature,
            markdown: generatedText
        )

        return WordMemoryAid(markdown: cache.markdown, generatedAt: cache.generatedAt, source: .generated)
    }

    private func requestValidatedMarkdown(
        using apiKey: String,
        model: MemoryAidModel,
        prompts: [String],
        word: WordRecord
    ) async throws -> String {
        var lastOutput = ""

        for (index, prompt) in prompts.enumerated() {
            let output = try await requestMarkdown(using: apiKey, model: model, prompt: prompt)
            if MemoryAidQualityGate.validate(output) {
                return output
            }
            lastOutput = output

            if index == prompts.count - 1 {
                break
            }
        }

        let repairedPrompt = MemoryAidPromptBuilder.repair(for: word, invalidOutput: lastOutput)
        let repairedOutput = try await requestMarkdown(using: apiKey, model: model, prompt: repairedPrompt)
        guard MemoryAidQualityGate.validate(repairedOutput) else {
            throw MemoryAidError.providerError("암기 도움 응답 품질이 기준을 만족하지 못했습니다. 다시 생성해 보세요.")
        }
        return repairedOutput
    }

    private func requestMarkdown(using apiKey: String, model: MemoryAidModel, prompt: String) async throws -> String {
        let requestBody = GeminiInteractionRequest(model: model.rawValue, input: prompt)

        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MemoryAidError.invalidResponse
        }

        if !(200..<300).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data) {
                throw MemoryAidError.providerError(apiError.error.message)
            }
            throw MemoryAidError.providerError("Gemini API 호출에 실패했습니다. (HTTP \(http.statusCode))")
        }

        let decoded = try JSONDecoder().decode(GeminiInteractionResponse.self, from: data)
        guard let output = decoded.outputText?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
            throw MemoryAidError.emptyResponse
        }
        return output
    }

    private func fetchCache(wordID: UUID, model: MemoryAidModel, signature: String) throws -> MemoryAidCacheRecord? {
        let modelRaw = model.rawValue
        let promptVersion = MemoryAidPromptBuilder.version
        let descriptor = FetchDescriptor<MemoryAidCacheRecord>(
            predicate: #Predicate { cache in
                cache.wordID == wordID &&
                cache.modelRaw == modelRaw &&
                cache.promptVersion == promptVersion &&
                cache.contentSignature == signature
            }
        )
        return try context.fetch(descriptor).first
    }

    private func upsertCache(wordID: UUID, model: MemoryAidModel, signature: String, markdown: String) throws -> MemoryAidCacheRecord {
        if let existing = try fetchCache(wordID: wordID, model: model, signature: signature) {
            existing.markdown = markdown
            existing.generatedAt = .now
            try pruneObsoleteCaches(keeping: existing, wordID: wordID, model: model)
            try context.save()
            return existing
        }

        let cache = MemoryAidCacheRecord(
            wordID: wordID,
            modelRaw: model.rawValue,
            promptVersion: MemoryAidPromptBuilder.version,
            contentSignature: signature,
            markdown: markdown
        )
        context.insert(cache)
        try pruneObsoleteCaches(keeping: cache, wordID: wordID, model: model)
        try context.save()
        return cache
    }

    private func pruneObsoleteCaches(keeping current: MemoryAidCacheRecord, wordID: UUID, model: MemoryAidModel) throws {
        let modelRaw = model.rawValue
        let descriptor = FetchDescriptor<MemoryAidCacheRecord>(
            predicate: #Predicate { cache in
                cache.wordID == wordID && cache.modelRaw == modelRaw
            }
        )
        let caches = try context.fetch(descriptor)
        for cache in caches where cache.id != current.id {
            context.delete(cache)
        }
    }
}

struct GeminiInteractionRequest: Encodable {
    let model: String
    let input: String
}

struct GeminiInteractionResponse: Decodable {
    struct Step: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }

        let type: String
        let content: [Content]?
    }

    let steps: [Step]

    var outputText: String? {
        steps
            .filter { $0.type == "model_output" }
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .joined(separator: "\n")
    }
}

struct GeminiErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

final class GeminiAPIKeyStore {
    static let shared = GeminiAPIKeyStore()

    private let service = "com.swainyun.Vocab.gemini"
    private let account = "api-key"

    func load() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.unhandled(status)
        }
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unhandled(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw KeychainStoreError.unhandled(updateStatus)
        }
    }

    func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandled(status)
        }
    }
}

enum KeychainStoreError: LocalizedError {
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            "키체인 저장소 처리에 실패했습니다. (OSStatus \(status))"
        }
    }
}
