import Foundation
import Security
import SwiftData

enum MemoryAidModel: String, CaseIterable, Identifiable {
    case gemini35Flash = "gemini-3.5-flash"
    case gemini31FlashLite = "gemini-3.1-flash-lite"

    static let defaultModel: MemoryAidModel = .gemini31FlashLite

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

    var fallbackModels: [MemoryAidModel] {
        switch self {
        case .gemini35Flash:
            [.gemini31FlashLite]
        case .gemini31FlashLite:
            []
        }
    }
}

struct WordMemoryAid: Equatable {
    let markdown: String
    let generatedAt: Date
    let source: Source
    let model: MemoryAidModel

    enum Source: Equatable {
        case cached
        case generated
    }
}

enum MemoryAidProgressStage: Equatable {
    case preparing
    case checkingCache
    case checkingQuota(model: MemoryAidModel)
    case quotaCoolingDown(model: MemoryAidModel, retryAfter: Date)
    case requesting(attempt: Int)
    case waitingToRetry
    case switchingModel(from: MemoryAidModel, to: MemoryAidModel)
    case validating(attempt: Int)
    case improvingQuality(attempt: Int)
    case saving
    case completedFromCache
    case completedGenerated

    var title: String {
        switch self {
        case .preparing:
            "요청 준비 중"
        case .checkingCache:
            "저장된 암기 도움 확인 중"
        case .checkingQuota:
            "API 호출 가능 여부 확인 중"
        case .quotaCoolingDown:
            "API 호출 대기 필요"
        case .requesting:
            "Gemini에 요청 중"
        case .waitingToRetry:
            "일시 오류 후 재시도 대기 중"
        case .switchingModel:
            "가벼운 모델로 전환 중"
        case .validating:
            "응답 품질 확인 중"
        case .improvingQuality:
            "응답 품질 보정 중"
        case .saving:
            "암기 도움 저장 중"
        case .completedFromCache:
            "저장된 암기 도움 불러옴"
        case .completedGenerated:
            "암기 도움 생성 완료"
        }
    }

    var detail: String {
        switch self {
        case .preparing:
            return "API 키와 단어 정보를 확인하고 있습니다."
        case .checkingCache:
            return "이미 생성된 결과가 있는지 먼저 확인합니다."
        case .checkingQuota(let model):
            return "\(model.displayName)의 최근 호출 제한 상태를 확인합니다."
        case .quotaCoolingDown(let model, let retryAfter):
            return "\(model.displayName)은 현재 호출 제한 대기 중입니다. \(retryAfter.formatted(date: .omitted, time: .shortened)) 이후 다시 시도할 수 있습니다."
        case .requesting(let attempt):
            return attempt == 1 ? "단어와 뜻을 바탕으로 암기 도움을 요청합니다." : "\(attempt)번째 요청을 보내고 있습니다."
        case .waitingToRetry:
            return "네트워크 또는 서버 응답이 불안정해 잠시 후 다시 시도합니다."
        case .switchingModel(let from, let to):
            return "\(from.displayName)의 API 한도가 일시적으로 막혀 \(to.displayName)로 다시 시도합니다."
        case .validating(let attempt):
            return attempt == 1 ? "응답 형식과 가독성 기준을 검사합니다." : "\(attempt)번째 응답의 품질을 검사합니다."
        case .improvingQuality(let attempt):
            return "\(attempt)번째 응답이 기준에 부족해 더 읽기 쉬운 형식으로 다시 요청합니다."
        case .saving:
            return "다음에 바로 열 수 있도록 결과를 저장합니다."
        case .completedFromCache:
            return "새 요청 없이 저장된 결과를 표시합니다."
        case .completedGenerated:
            return "생성된 결과를 화면에 표시합니다."
        }
    }
}

typealias MemoryAidProgressHandler = @MainActor (MemoryAidProgressStage) -> Void

enum MemoryAidError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case emptyResponse
    case requestTimedOut
    case rateLimited(model: MemoryAidModel, retryAfter: Date?)
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
        case .rateLimited(let model, let retryAfter):
            if let retryAfter {
                "\(model.displayName)의 API 호출 한도에 일시적으로 걸렸습니다. \(retryAfter.formatted(date: .omitted, time: .shortened)) 이후 다시 시도하세요."
            } else {
                "\(model.displayName)의 API 호출 한도에 일시적으로 걸렸습니다. 잠시 후 다시 시도하거나 설정에서 더 가벼운 모델을 선택하세요."
            }
        case .providerError(let message):
            message
        }
    }

    static func userFacingMessage(for error: Error) -> String {
        if let memoryAidError = error as? MemoryAidError {
            return memoryAidError.errorDescription ?? "암기 도움 생성 중 문제가 발생했습니다."
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Gemini 응답 대기 시간이 길어 요청을 중단했습니다. 잠시 후 다시 시도하세요."
            case .notConnectedToInternet, .networkConnectionLost:
                return "네트워크 연결이 불안정합니다. 인터넷 상태를 확인한 뒤 다시 시도하세요."
            case .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost:
                return "Gemini 서버에 연결하지 못했습니다. 잠시 후 다시 시도하세요."
            case .badServerResponse:
                return "Gemini 서버 응답이 일시적으로 불안정합니다. 잠시 후 다시 시도하세요."
            default:
                return "암기 도움 생성 중 네트워크 문제가 발생했습니다. 잠시 후 다시 시도하세요."
            }
        }

        return "암기 도움 생성 중 문제가 발생했습니다. 잠시 후 다시 시도하세요."
    }
}

enum MemoryAidRequestPolicy {
    static let requestTimeout: TimeInterval = 45
    static let defaultRateLimitCooldown: TimeInterval = 90
    static let qualityRetryBudget: Duration = .seconds(10)
    static let maxQualityAttempts = 3
    static let maxOutputTokens = 650
    static let transientRetryDelays: [Duration] = [
        .milliseconds(350),
        .seconds(1)
    ]

    static func shouldRetryHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || (500...599).contains(statusCode)
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
    private let quotaCooldownStore: GeminiQuotaCooldownStore

    init(
        context: ModelContext,
        session: URLSession = .shared,
        apiKeyStore: GeminiAPIKeyStore = .shared,
        quotaCooldownStore: GeminiQuotaCooldownStore = .shared
    ) {
        self.context = context
        self.session = session
        self.apiKeyStore = apiKeyStore
        self.quotaCooldownStore = quotaCooldownStore
    }

    func generate(
        for word: WordRecord,
        model: MemoryAidModel,
        forceRefresh: Bool = false,
        onProgress: MemoryAidProgressHandler? = nil
    ) async throws -> WordMemoryAid {
        onProgress?(.preparing)
        guard let apiKey = try apiKeyStore.load(), !apiKey.isEmpty else {
            throw MemoryAidError.missingAPIKey
        }

        do {
            let signature = MemoryAidQualityGate.contentSignature(for: word)
            let modelsToTry = [model] + model.fallbackModels
            var lastRateLimit: MemoryAidError?

            for candidateModel in modelsToTry {
                onProgress?(.checkingCache)
                if !forceRefresh, let cached = try fetchCache(wordID: word.id, model: candidateModel, signature: signature) {
                    onProgress?(.completedFromCache)
                    return WordMemoryAid(markdown: cached.markdown, generatedAt: cached.generatedAt, source: .cached, model: candidateModel)
                }

                if candidateModel != model {
                    onProgress?(.switchingModel(from: model, to: candidateModel))
                }

                onProgress?(.checkingQuota(model: candidateModel))
                if let retryAfter = quotaCooldownStore.retryAfter(for: candidateModel) {
                    onProgress?(.quotaCoolingDown(model: candidateModel, retryAfter: retryAfter))
                    lastRateLimit = .rateLimited(model: candidateModel, retryAfter: retryAfter)
                    continue
                }

                do {
                    let generatedText = try await requestValidatedMarkdown(
                        using: apiKey,
                        model: candidateModel,
                        prompts: [
                            MemoryAidPromptBuilder.build(for: word)
                        ],
                        word: word,
                        onProgress: onProgress
                    )
                    onProgress?(.saving)
                    let cache = try upsertCache(
                        wordID: word.id,
                        model: candidateModel,
                        signature: signature,
                        markdown: generatedText
                    )

                    onProgress?(.completedGenerated)
                    return WordMemoryAid(markdown: cache.markdown, generatedAt: cache.generatedAt, source: .generated, model: candidateModel)
                } catch let error as MemoryAidError {
                    if case .rateLimited = error {
                        lastRateLimit = error
                        continue
                    }
                    throw error
                }
            }

            if let lastRateLimit {
                throw lastRateLimit
            }
            throw MemoryAidError.providerError("Gemini API 호출에 실패했습니다. 잠시 후 다시 시도하세요.")
        } catch {
            if error is MemoryAidError {
                throw error
            }
            throw MemoryAidError.providerError(MemoryAidError.userFacingMessage(for: error))
        }
    }

    private func requestValidatedMarkdown(
        using apiKey: String,
        model: MemoryAidModel,
        prompts: [String],
        word: WordRecord,
        onProgress: MemoryAidProgressHandler?
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: MemoryAidRequestPolicy.qualityRetryBudget)
        var lastOutput = ""
        var attempt = 0
        var promptQueue = prompts

        while attempt < MemoryAidRequestPolicy.maxQualityAttempts, let prompt = promptQueue.first {
            promptQueue.removeFirst()
            attempt += 1

            onProgress?(.requesting(attempt: attempt))
            let output = try await requestMarkdownWithRetries(
                using: apiKey,
                model: model,
                prompt: prompt,
                attempt: attempt,
                onProgress: onProgress
            )
            onProgress?(.validating(attempt: attempt))
            if let normalized = MemoryAidQualityGate.normalize(output) {
                return normalized
            }
            lastOutput = output

            guard clock.now < deadline else {
                break
            }

            onProgress?(.improvingQuality(attempt: attempt))
            promptQueue.append(MemoryAidPromptBuilder.repair(for: word, invalidOutput: lastOutput))
        }

        if lastOutput.isEmpty {
            throw MemoryAidError.providerError("암기 도움 응답을 만들지 못했습니다. 잠시 후 다시 시도하세요.")
        }
        throw MemoryAidError.providerError("암기 도움 응답 품질이 기준을 만족하지 못했습니다. 자동 재시도 후에도 개선되지 않아 중단했습니다.")
    }

    private func requestMarkdownWithRetries(
        using apiKey: String,
        model: MemoryAidModel,
        prompt: String,
        attempt: Int,
        onProgress: MemoryAidProgressHandler?
    ) async throws -> String {
        var lastError: Error?

        let retrySchedule: [(Int, Duration)] = [(0, .zero)] + MemoryAidRequestPolicy.transientRetryDelays.enumeratedDurations()

        for (retryAttempt, delay) in retrySchedule {
            do {
                if retryAttempt > 0 {
                    onProgress?(.waitingToRetry)
                    try await Task.sleep(for: delay)
                    onProgress?(.requesting(attempt: attempt))
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
        let requestBody = GeminiGenerateContentRequest(
            contents: [
                .init(
                    role: "user",
                    parts: [
                        .init(text: prompt)
                    ]
                )
            ],
            generationConfig: .init(
                temperature: 0.35,
                maxOutputTokens: MemoryAidRequestPolicy.maxOutputTokens
            )
        )

        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent"
        var request = URLRequest(url: URL(string: endpoint)!)
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
                throw Self.providerError(
                    statusCode: http.statusCode,
                    model: model,
                    response: http,
                    quotaCooldownStore: quotaCooldownStore,
                    providerMessage: apiError.error.message
                )
            }
            throw Self.providerError(
                statusCode: http.statusCode,
                model: model,
                response: http,
                quotaCooldownStore: quotaCooldownStore,
                providerMessage: nil
            )
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
        guard let output = decoded.outputText?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
            throw MemoryAidError.emptyResponse
        }
        return output
    }

    private static func providerError(
        statusCode: Int,
        model: MemoryAidModel,
        response: HTTPURLResponse,
        quotaCooldownStore: GeminiQuotaCooldownStore,
        providerMessage: String?
    ) -> MemoryAidError {
        if statusCode == 429 {
            let retryAfter = quotaCooldownStore.recordRateLimit(for: model, response: response)
            return .rateLimited(model: model, retryAfter: retryAfter)
        }
        return .providerError(providerStatusMessage(statusCode: statusCode, providerMessage: providerMessage))
    }

    private static func providerStatusMessage(statusCode: Int, providerMessage: String?) -> String {
        switch statusCode {
        case 400:
            return "Gemini 요청 형식이 올바르지 않습니다. 앱을 최신 상태로 다시 설치한 뒤 재시도하세요."
        case 401, 403:
            return "Gemini API 키가 유효하지 않거나 권한이 없습니다. 설정에서 API 키를 다시 확인하세요."
        case 404:
            return "선택한 Gemini 모델을 사용할 수 없습니다. 설정에서 다른 모델을 선택한 뒤 재시도하세요."
        default:
            if let providerMessage, !providerMessage.isEmpty {
                return "Gemini API 호출에 실패했습니다. \(providerMessage)"
            }
            return "Gemini API 호출에 실패했습니다. 잠시 후 다시 시도하세요."
        }
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

struct GeminiGenerateContentRequest: Encodable {
    struct Content: Encodable {
        let role: String
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let maxOutputTokens: Int
    }

    let contents: [Content]
    let generationConfig: GenerationConfig
}

struct GeminiGenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }

            let parts: [Part]?
        }

        let content: Content?
    }

    let candidates: [Candidate]?

    var outputText: String? {
        candidates?
            .compactMap(\.content)
            .flatMap { $0.parts ?? [] }
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

final class GeminiQuotaCooldownStore {
    static let shared = GeminiQuotaCooldownStore()

    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "memoryAidQuotaCooldown."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func retryAfter(for model: MemoryAidModel, now: Date = .now) -> Date? {
        let key = key(for: model)
        let timestamp = defaults.double(forKey: key)
        guard timestamp > 0 else { return nil }

        let retryAfter = Date(timeIntervalSince1970: timestamp)
        guard retryAfter > now else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return retryAfter
    }

    @discardableResult
    func recordRateLimit(
        for model: MemoryAidModel,
        response: HTTPURLResponse,
        now: Date = .now
    ) -> Date {
        let retryAfter = parseRetryAfter(response: response, now: now)
            ?? now.addingTimeInterval(MemoryAidRequestPolicy.defaultRateLimitCooldown)
        defaults.set(retryAfter.timeIntervalSince1970, forKey: key(for: model))
        return retryAfter
    }

    private func key(for model: MemoryAidModel) -> String {
        "\(keyPrefix)\(model.rawValue)"
    }

    private func parseRetryAfter(response: HTTPURLResponse, now: Date) -> Date? {
        guard let value = retryAfterHeaderValue(response) else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return now.addingTimeInterval(max(0, seconds))
        }
        return Self.retryAfterDateFormatter.date(from: value)
    }

    private func retryAfterHeaderValue(_ response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard
                let header = key as? String,
                header.caseInsensitiveCompare("Retry-After") == .orderedSame
            else {
                continue
            }
            return String(describing: value)
        }
        return nil
    }

    private static let retryAfterDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
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
