import XCTest
@testable import Vocab

final class MemoryAidServiceTests: XCTestCase {
    func testOutputTextConcatenatesModelOutputStepsOnly() throws {
        let response = try JSONDecoder().decode(
            GeminiInteractionResponse.self,
            from: Data(
                """
                {
                  "steps": [
                    { "type": "thought" },
                    {
                      "type": "model_output",
                      "content": [
                        { "type": "text", "text": "## 한줄 기억\\n핵심" },
                        { "type": "text", "text": "## 예문\\nExample" }
                      ]
                    }
                  ]
                }
                """.utf8
            )
        )

        XCTAssertEqual(response.outputText, "## 한줄 기억\n핵심\n## 예문\nExample")
    }

    func testPromptBuilderIncludesHeadwordAndMeanings() {
        let word = WordRecord(term: "derive")
        let meaning = MeaningRecord(text: "끌어내다")
        meaning.word = word
        word.meanings.append(meaning)

        let prompt = MemoryAidPromptBuilder.build(for: word)

        XCTAssertTrue(prompt.contains("Word: derive"))
        XCTAssertTrue(prompt.contains("Meanings: 끌어내다"))
        XCTAssertTrue(prompt.contains("## 한줄 기억"))
        XCTAssertTrue(prompt.contains("## 비교"))
    }

    func testQualityGateAcceptsRequiredSectionTemplate() {
        let markdown = """
        ## 한줄 기억
        핵심 기억
        ## 형태/어원
        불확실하면 불확실하다고 표시
        ## 연상 포인트
        소리 연상
        ## 예문
        I derive energy from study.
        공부에서 힘을 얻는다.
        ## 비교
        drive와 헷갈리지 말기
        """

        XCTAssertTrue(MemoryAidQualityGate.validate(markdown))
    }

    func testQualityGateRejectsMissingSections() {
        XCTAssertFalse(MemoryAidQualityGate.validate("## 한줄 기억\n하나만 있음"))
    }
}
