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
    case requestTimedOut
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "설정에서 Gemini API 키를 먼저 입력하세요."
        case .invalidResponse:
            "암기 도움 응답 형식을 해석하지 못했습니다."
        case .emptyResponse:
            "암기 도움 내용을 받지 못했습니다."
        case .requestTimedOut:
            "Gemini 응답 대기 시간이 길어 요청을 중단했습니다. 잠시 후 다시 시도하세요."
        case .providerError(let message):
            message
        }
    }
}

enum MemoryAidRequestPolicy {
    static let requestTimeout: TimeInterval = 45
    static let qualityRetryBudget: Duration = .seconds(18)
    static let maxQualityAttempts = 6
    static let transientRetryDelays: [Duration] = [
        .milliseconds(350),
        .seconds(1)
    ]

    static func shouldRetryHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    static func shouldRetry(error: Error) -> Bool {
        if let memoryAidError = error as? MemoryAidError {
            if case .requestTimedOut = memoryAidError {
                return true
            }
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed, .badServerResponse:
            return true
        default:
            return false
        }
    }
}

struct MemoryAidPromptBuilder {
    static let version = 3

    static func build(for word: WordRecord) -> String {
        let meanings = word.meanings.map(\.text).joined(separator: ", ")

        return """
        You are helping a Korean learner memorize one English vocabulary item for a public-service exam.

        Word: \(word.term)
        Meanings: \(meanings)

        Write concise study help in Korean using Markdown.
        Follow these rules:
        - Be accurate. If etymology or a comparison is uncertain, say that it is uncertain instead of fabricating.
        - Keep the whole answer short and scannable. Prefer short noun phrases over long sentences.
        - Prefer practical memorization help over encyclopedia-style explanation.
        - Output must use exactly these sections in this order:
          ## 한줄 기억
          ## 형태/어원
          ## 연상 포인트
          ## 예문
          ## 비교
        - Under ## 한줄 기억, write exactly one bullet line: "- ..."
        - Under ## 형태/어원, write exactly one bullet line: "- ..."
        - Under ## 연상 포인트, write exactly one bullet line: "- ..."
        - Under ## 예문, write exactly two bullet lines:
          - EN: ...
          - KO: ...
        - Under ## 비교, write exactly one bullet line: "- ..."
        - Separate each section with one blank line.
        - Do not use bold, numbering, extra headings, code blocks, or paragraphs.
        - Keep each bullet readable at a glance. Avoid semicolons and chained clauses.
        - In 비교, prefer similar/confusable words or antonyms only when actually useful. If not useful, write "- 없음".
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
        - Use all five headings exactly once and in this order:
          ## 한줄 기억
          ## 형태/어원
          ## 연상 포인트
          ## 예문
          ## 비교
        - Do not invent uncertain etymology or comparisons.
        - Use this exact line structure:
          ## 한줄 기억
          - ...

          ## 형태/어원
          - ...

          ## 연상 포인트
          - ...

          ## 예문
          - EN: ...
          - KO: ...

          ## 비교
          - ...
        - No extra text before, after, or between sections except one blank line.
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

    struct ParsedMemoryAid: Equatable {
        let hook: String
        let etymology: String
        let association: String
        let exampleEnglish: String
        let exampleKorean: String
        let comparison: String

        var normalizedMarkdown: String {
            """
            ## 한줄 기억
            - \(hook)

            ## 형태/어원
            - \(etymology)

            ## 연상 포인트
            - \(association)

            ## 예문
            - EN: \(exampleEnglish)
            - KO: \(exampleKorean)

            ## 비교
            - \(comparison)
            """
        }
    }

    static func validate(_ markdown: String) -> Bool {
        parse(markdown) != nil
    }

    static func normalize(_ markdown: String) -> String? {
        parse(markdown)?.normalizedMarkdown
    }

    static func parsed(_ markdown: String) -> ParsedMemoryAid? {
        parse(markdown)
    }

    private static func parse(_ markdown: String) -> ParsedMemoryAid? {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1_400 else { return nil }
        guard requiredSections.allSatisfy(trimmed.contains) else { return nil }
        guard requiredSections.allSatisfy({ heading in trimmed.components(separatedBy: heading).count == 2 }) else { return nil }

        let blocks = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard blocks.count == requiredSections.count else { return nil }

        var values: [String: [String]] = [:]
        for (index, block) in blocks.enumerated() {
            let lines = block
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let heading = lines.first, heading == requiredSections[index] else { return nil }
            let contentLines = Array(lines.dropFirst())
            guard !contentLines.isEmpty else { return nil }
            values[heading] = contentLines
        }

        guard
            let hook = parseSingleBullet(values["## 한줄 기억"]),
            let etymology = parseSingleBullet(values["## 형태/어원"]),
            let association = parseSingleBullet(values["## 연상 포인트"]),
            let comparison = parseSingleBullet(values["## 비교"]),
            let example = parseExample(values["## 예문"])
        else {
            return nil
        }

        return ParsedMemoryAid(
            hook: hook,
            etymology: etymology,
            association: association,
            exampleEnglish: example.english,
            exampleKorean: example.korean,
            comparison: comparison
        )
    }

    private static func parseSingleBullet(_ lines: [String]?) -> String? {
        guard let lines, lines.count == 1 else { return nil }
        guard lines[0].hasPrefix("- ") else { return nil }
        let value = String(lines[0].dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReadable(value, maxLength: 80) else { return nil }
        return value
    }

    private static func parseExample(_ lines: [String]?) -> (english: String, korean: String)? {
        guard let lines, lines.count == 2 else { return nil }
        guard lines[0].hasPrefix("- EN: "), lines[1].hasPrefix("- KO: ") else { return nil }
        let english = String(lines[0].dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        let korean = String(lines[1].dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReadable(english, maxLength: 100), isReadable(korean, maxLength: 100) else { return nil }
        return (english, korean)
    }

    private static func isReadable(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maxLength else { return false }
        guard !value.contains("\n"), !value.contains("```"), !value.contains("##") else { return false }
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: MemoryAidRequestPolicy.qualityRetryBudget)
        var lastOutput = ""
        var attempt = 0
        var promptQueue = prompts

        while attempt < MemoryAidRequestPolicy.maxQualityAttempts, let prompt = promptQueue.first {
            promptQueue.removeFirst()
            attempt += 1

            let output = try await requestMarkdownWithRetries(using: apiKey, model: model, prompt: prompt)
            if let normalized = MemoryAidQualityGate.normalize(output) {
                return normalized
            }
            lastOutput = output

            guard clock.now < deadline else {
                break
            }

            promptQueue.append(MemoryAidPromptBuilder.repair(for: word, invalidOutput: lastOutput))
        }

        if lastOutput.isEmpty {
            throw MemoryAidError.providerError("암기 도움 응답을 만들지 못했습니다. 잠시 후 다시 시도하세요.")
        }
        throw MemoryAidError.providerError("암기 도움 응답 품질이 기준을 만족하지 못했습니다. 자동 재시도 후에도 개선되지 않아 중단했습니다.")
    }

    private func requestMarkdownWithRetries(using apiKey: String, model: MemoryAidModel, prompt: String) async throws -> String {
        var lastError: Error?

        let retrySchedule: [(Int, Duration)] = [(0, .zero)] + MemoryAidRequestPolicy.transientRetryDelays.enumeratedDurations()

        for (attempt, delay) in retrySchedule {
            do {
                if attempt > 0 {
                    try await Task.sleep(for: delay)
                }
                return try await requestMarkdown(using: apiKey, model: model, prompt: prompt)
            } catch {
                lastError = error
                if !MemoryAidRequestPolicy.shouldRetry(error: error) {
                    throw error
                }
            }
        }

        if let urlError = lastError as? URLError, urlError.code == .timedOut {
            throw MemoryAidError.requestTimedOut
        }
        if let lastError {
            throw lastError
        }
        throw MemoryAidError.invalidResponse
    }

    private func requestMarkdown(using apiKey: String, model: MemoryAidModel, prompt: String) async throws -> String {
        let requestBody = GeminiInteractionRequest(model: model.rawValue, input: prompt)

        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = MemoryAidRequestPolicy.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw MemoryAidError.requestTimedOut
        }
        guard let http = response as? HTTPURLResponse else {
            throw MemoryAidError.invalidResponse
        }

        if !(200..<300).contains(http.statusCode) {
            if MemoryAidRequestPolicy.shouldRetryHTTPStatus(http.statusCode) {
                throw URLError(.badServerResponse)
            }
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

private extension Array where Element == Duration {
    func enumeratedDurations() -> [(Int, Duration)] {
        enumerated().map { ($0.offset + 1, $0.element) }
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
