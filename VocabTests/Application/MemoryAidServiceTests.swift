import XCTest
@testable import Vocab

final class MemoryAidServiceTests: XCTestCase {
    func testGenerateContentResponseConcatenatesCandidateTextParts() throws {
        let response = try JSONDecoder().decode(
            GeminiGenerateContentResponse.self,
            from: Data(
                """
                {
                  "candidates": [
                    {
                      "content": {
                        "parts": [
                          { "text": "## 한줄 기억\\n핵심" },
                          { "text": "## 예문\\nExample" }
                        ]
                      }
                    }
                  ]
                }
                """.utf8
            )
        )

        XCTAssertEqual(response.outputText, "## 한줄 기억\n핵심\n## 예문\nExample")
    }

    func testGenerateContentRequestUsesContentsPartsShape() throws {
        let request = GeminiGenerateContentRequest(
            contents: [
                .init(role: "user", parts: [.init(text: "prompt")])
            ],
            generationConfig: .init(temperature: 0.35, maxOutputTokens: MemoryAidRequestPolicy.maxOutputTokens)
        )

        let json = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains("\"contents\""))
        XCTAssertTrue(json.contains("\"parts\""))
        XCTAssertTrue(json.contains("\"text\":\"prompt\""))
        XCTAssertTrue(json.contains("\"generationConfig\""))
        XCTAssertFalse(json.contains("\"input\""))
    }

    func testDefaultModelUsesLowerQuotaPressureModel() {
        XCTAssertEqual(MemoryAidModel.defaultModel, .gemini31FlashLite)
        XCTAssertEqual(MemoryAidModel.gemini35Flash.fallbackModels, [.gemini31FlashLite])
        XCTAssertTrue(MemoryAidModel.gemini31FlashLite.fallbackModels.isEmpty)
    }

    func testPromptBuilderIncludesHeadwordAndMeanings() {
        let word = WordRecord(term: "derive")
        let meaning = MeaningRecord(text: "끌어내다")
        meaning.word = word
        word.appendMeaning(meaning)

        let prompt = MemoryAidPromptBuilder.build(for: word)

        XCTAssertEqual(MemoryAidPromptBuilder.version, 4)
        XCTAssertTrue(prompt.contains("Word: derive"))
        XCTAssertTrue(prompt.contains("Meanings: 끌어내다"))
        XCTAssertTrue(prompt.contains("## 한줄 기억"))
        XCTAssertTrue(prompt.contains("## 비교"))
        XCTAssertTrue(prompt.contains("specific to this word"))
        XCTAssertTrue(prompt.contains("English example must use"))
    }

    func testQualityGateAcceptsRequiredSectionTemplate() {
        let markdown = """
        ## 한줄 기억
        - derive는 안에서 밖으로 뜻을 끌어내는 느낌

        ## 형태/어원
        - de-와 rive 연결은 불확실하므로 의미 중심으로 기억

        ## 연상 포인트
        - 드라이브에서 방향을 끌어내듯 원천에서 얻는 장면

        ## 예문
        - EN: I derive energy from study.
        - KO: 공부에서 힘을 얻는다.

        ## 비교
        - drive와 헷갈리지 말기
        """

        XCTAssertTrue(MemoryAidQualityGate.validate(markdown))
    }

    func testQualityGateRejectsMissingSections() {
        XCTAssertFalse(MemoryAidQualityGate.validate("## 한줄 기억\n하나만 있음"))
    }

    func testQualityGateRejectsUnreadableStructure() {
        let markdown = """
        ## 한줄 기억
        - 핵심 기억
        - 줄이 두 개

        ## 형태/어원
        - derive는 ...

        ## 연상 포인트
        - 소리 연상

        ## 예문
        - EN: I derive energy from study.
        - KO: 공부에서 힘을 얻는다.

        ## 비교
        - drive와 헷갈리지 말기
        """

        XCTAssertFalse(MemoryAidQualityGate.validate(markdown))
    }

    func testQualityGateRejectsPlaceholderContent() {
        let markdown = """
        ## 한줄 기억
        - 핵심 기억

        ## 형태/어원
        - 설명 필요

        ## 연상 포인트
        - 소리 연상

        ## 예문
        - EN: Example sentence here.
        - KO: 예문 작성 필요

        ## 비교
        - ...
        """

        XCTAssertFalse(MemoryAidQualityGate.validate(markdown))
    }

    func testQualityGateRejectsOverlyShortContent() {
        let markdown = """
        ## 한줄 기억
        - 짧음

        ## 형태/어원
        - 짧다

        ## 연상 포인트
        - 짧다

        ## 예문
        - EN: Too short.
        - KO: 짧다

        ## 비교
        - 없음
        """

        XCTAssertFalse(MemoryAidQualityGate.validate(markdown))
    }

    func testQualityGateNormalizesValidOutput() {
        let markdown = """
        ## 한줄 기억
          - derive는 근원에서 결과를 끌어내는 동사

        ## 형태/어원
         - 어원 설명은 불확실하니 from과 함께 의미를 고정

        ## 연상 포인트
        - 자료에서 결론을 끌어내는 시험 지문 장면

        ## 예문
        - EN: I derive energy from study.
        - KO: 공부에서 힘을 얻는다.

        ## 비교
        - drive와 헷갈리지 말기
        """

        let normalized = MemoryAidQualityGate.normalize(markdown)

        XCTAssertEqual(
            normalized,
            """
            ## 한줄 기억
            - derive는 근원에서 결과를 끌어내는 동사

            ## 형태/어원
            - 어원 설명은 불확실하니 from과 함께 의미를 고정

            ## 연상 포인트
            - 자료에서 결론을 끌어내는 시험 지문 장면

            ## 예문
            - EN: I derive energy from study.
            - KO: 공부에서 힘을 얻는다.

            ## 비교
            - drive와 헷갈리지 말기
            """
        )
    }

    func testRequestPolicyRetriesTransientHTTPStatus() {
        XCTAssertTrue(MemoryAidRequestPolicy.shouldRetryHTTPStatus(408))
        XCTAssertTrue(MemoryAidRequestPolicy.shouldRetryHTTPStatus(503))
        XCTAssertFalse(MemoryAidRequestPolicy.shouldRetryHTTPStatus(400))
        XCTAssertFalse(MemoryAidRequestPolicy.shouldRetryHTTPStatus(429))
    }

    func testRequestPolicyCapsQualityRetriesAndOutputSize() {
        XCTAssertEqual(MemoryAidRequestPolicy.maxQualityAttempts, 3)
        XCTAssertGreaterThanOrEqual(MemoryAidRequestPolicy.maxOutputTokens, 750)
        XCTAssertLessThanOrEqual(MemoryAidRequestPolicy.maxOutputTokens, 900)
        XCTAssertEqual(MemoryAidRequestPolicy.defaultRateLimitCooldown, 90)
    }

    func testRequestPolicyRetriesTimeoutAndTransientNetworkErrors() {
        XCTAssertTrue(MemoryAidRequestPolicy.shouldRetry(error: URLError(.timedOut)))
        XCTAssertTrue(MemoryAidRequestPolicy.shouldRetry(error: URLError(.badServerResponse)))
        XCTAssertTrue(MemoryAidRequestPolicy.shouldRetry(error: MemoryAidError.requestTimedOut))
        XCTAssertFalse(MemoryAidRequestPolicy.shouldRetry(error: URLError(.userAuthenticationRequired)))
    }

    func testUserFacingMessageMapsSystemErrorsToNaturalLanguage() {
        XCTAssertEqual(
            MemoryAidError.userFacingMessage(for: URLError(.timedOut)),
            "Gemini 응답 대기 시간이 길어 요청을 중단했습니다. 잠시 후 다시 시도하세요."
        )
        XCTAssertEqual(
            MemoryAidError.userFacingMessage(for: URLError(.notConnectedToInternet)),
            "네트워크 연결이 불안정합니다. 인터넷 상태를 확인한 뒤 다시 시도하세요."
        )
        XCTAssertEqual(
            MemoryAidError.userFacingMessage(for: URLError(.badServerResponse)),
            "Gemini 서버 응답이 일시적으로 불안정합니다. 잠시 후 다시 시도하세요."
        )
    }

    func testRateLimitErrorMentionsModelAndLighterModel() {
        let message = MemoryAidError.userFacingMessage(for: MemoryAidError.rateLimited(model: .gemini35Flash, retryAfter: nil))

        XCTAssertTrue(message.contains("Gemini 3.5 Flash"))
        XCTAssertTrue(message.contains("가벼운 모델"))
    }

    func testRateLimitCooldownStoreUsesRetryAfterSeconds() {
        let defaults = UserDefaults(suiteName: "VocabTests.\(UUID().uuidString)")!
        let store = GeminiQuotaCooldownStore(defaults: defaults, keyPrefix: "testQuota.")
        let now = Date(timeIntervalSince1970: 1_000)
        let response = HTTPURLResponse(
            url: URL(string: "https://generativelanguage.googleapis.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "120"]
        )!

        let retryAfter = store.recordRateLimit(for: .gemini35Flash, response: response, now: now)

        XCTAssertEqual(retryAfter.timeIntervalSince(now), 120, accuracy: 0.001)
        XCTAssertEqual(store.retryAfter(for: .gemini35Flash, now: now.addingTimeInterval(60)), retryAfter)
        XCTAssertNil(store.retryAfter(for: .gemini35Flash, now: now.addingTimeInterval(121)))
    }

    func testRateLimitCooldownStoreFallsBackWhenRetryAfterHeaderIsMissing() {
        let defaults = UserDefaults(suiteName: "VocabTests.\(UUID().uuidString)")!
        let store = GeminiQuotaCooldownStore(defaults: defaults, keyPrefix: "testQuota.")
        let now = Date(timeIntervalSince1970: 1_000)
        let response = HTTPURLResponse(
            url: URL(string: "https://generativelanguage.googleapis.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: [:]
        )!

        let retryAfter = store.recordRateLimit(for: .gemini31FlashLite, response: response, now: now)

        XCTAssertEqual(retryAfter.timeIntervalSince(now), MemoryAidRequestPolicy.defaultRateLimitCooldown, accuracy: 0.001)
        XCTAssertEqual(store.retryAfter(for: .gemini31FlashLite, now: now), retryAfter)
    }

    func testProgressStageProvidesUserReadableStatus() {
        XCTAssertEqual(MemoryAidProgressStage.preparing.title, "요청 준비 중")
        XCTAssertEqual(MemoryAidProgressStage.checkingQuota(model: .gemini31FlashLite).title, "API 호출 가능 여부 확인 중")
        XCTAssertEqual(MemoryAidProgressStage.requesting(attempt: 1).detail, "단어와 뜻을 바탕으로 암기 도움을 요청합니다.")
        XCTAssertEqual(MemoryAidProgressStage.requesting(attempt: 2).detail, "2번째 요청을 보내고 있습니다.")
        XCTAssertEqual(MemoryAidProgressStage.validating(attempt: 2).detail, "2번째 응답의 품질을 검사합니다.")
        XCTAssertFalse(MemoryAidProgressStage.quotaCoolingDown(model: .gemini31FlashLite, retryAfter: .now).detail.isEmpty)
        XCTAssertFalse(MemoryAidProgressStage.waitingToRetry.detail.isEmpty)
    }
}
