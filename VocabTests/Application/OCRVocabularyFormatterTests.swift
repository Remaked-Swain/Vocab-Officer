import CoreGraphics
import XCTest
@testable import Vocab

final class OCRVocabularyFormatterTests: XCTestCase {
    func testFormatsTwoColumnVocabularyPageByCoordinates() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0501", x: 0.150, y: 0.714),
            token("pill", x: 0.231, y: 0.729),
            token("알약", x: 0.227, y: 0.715),
            token("[pil]", x: 0.462, y: 0.734),
            token("0511", x: 0.528, y: 0.713),
            token("joke", x: 0.615, y: 0.731),
            token("농담, 농담을 하다", x: 0.622, y: 0.713),
            token("[d3ouk]", x: 0.825, y: 0.734),
            token("DAY06", x: 0.694, y: 0.795),
            token("29", x: 0.863, y: 0.049)
        ])

        XCTAssertEqual(
            output,
            """
            0501-pill-알약
            0511-joke-농담, 농담을 하다
            """
        )
    }

    func testPreservesSelectedPageOrderInsteadOfSortingByRestartedNumber() throws {
        let output = try OCRVocabularyFormatter.formatPages([
            [
                token("10001", x: 0.119, y: 0.714),
                token("master", x: 0.206, y: 0.733),
                token("주인, 명인, 정복하다", x: 0.206, y: 0.714)
            ],
            [
                token("0501", x: 0.150, y: 0.714),
                token("pill", x: 0.231, y: 0.729),
                token("알약", x: 0.227, y: 0.715)
            ]
        ])

        XCTAssertEqual(
            output,
            """
            10001-master-주인, 명인, 정복하다
            0501-pill-알약
            """
        )
    }

    func testPreservesRepeatedPrintedNumbersAcrossPages() throws {
        let output = try OCRVocabularyFormatter.formatPages([
            [
                token("0001", x: 0.150, y: 0.714),
                token("legacy", x: 0.231, y: 0.729),
                token("기존", x: 0.227, y: 0.715)
            ],
            [
                token("0001", x: 0.150, y: 0.714),
                token("renewal", x: 0.231, y: 0.729),
                token("새로운 것", x: 0.227, y: 0.715)
            ]
        ])

        XCTAssertEqual(
            output,
            """
            0001-legacy-기존
            0001-renewal-새로운 것
            """
        )
    }

    func testInfersLayoutWhenPrintedNumberIsToTheRightOfVocabulary() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0001", x: 0.420, y: 0.714),
            token("adapt", x: 0.150, y: 0.729),
            token("적응하다", x: 0.150, y: 0.700)
        ])

        XCTAssertEqual(output, "0001-adapt-적응하다")
    }

    func testFormatsNumberTermAndMeaningOnSeparateLines() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0001", x: 0.150, y: 0.760, height: 0.014),
            token("categorically", x: 0.150, y: 0.738, height: 0.020),
            token("[kætəgɔːrikəli]", x: 0.300, y: 0.738),
            token("절대적으로, 단정적으로, 명확히", x: 0.150, y: 0.714),
            token("0002", x: 0.150, y: 0.680, height: 0.014),
            token("obsolete", x: 0.150, y: 0.658, height: 0.020),
            token("구식의, 한물 간, 시대에 뒤떨어진", x: 0.150, y: 0.634)
        ])

        XCTAssertEqual(
            output,
            """
            0001-categorically-절대적으로, 단정적으로, 명확히
            0002-obsolete-구식의, 한물 간, 시대에 뒤떨어진
            """
        )
    }

    func testRemovesMergedPronunciationAndPreservesMultiwordTerm() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0001", x: 0.150, y: 0.760),
            token("impair timpear", x: 0.150, y: 0.738),
            token("손상시키다, 악화시키다", x: 0.150, y: 0.714),
            token("0002", x: 0.150, y: 0.680),
            token("general election Id3enaral ilek/an]", x: 0.150, y: 0.658),
            token("총선", x: 0.150, y: 0.634)
        ])

        XCTAssertEqual(
            output,
            """
            0001-impair-손상시키다, 악화시키다
            0002-general election-총선
            """
        )
    }

    func testPrefersLeftmostHeadwordWhenPronunciationIsCloserToNumberLine() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0001", x: 0.150, y: 0.760),
            token("categorically", x: 0.150, y: 0.738),
            token("kaetegorikeli", x: 0.320, y: 0.758),
            token("절대적으로, 명확히", x: 0.150, y: 0.714)
        ])

        XCTAssertEqual(output, "0001-categorically-절대적으로, 명확히")
    }

    func testRemovesPronunciationMergedIntoSameUnbracketedToken() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0001", x: 0.150, y: 0.760),
            token("categorically kaetegorikeli", x: 0.150, y: 0.738),
            token("절대적으로, 명확히", x: 0.150, y: 0.714)
        ])

        XCTAssertEqual(output, "0001-categorically-절대적으로, 명확히")
    }

    func testPreservesGenuineMultiwordHeadwordWithoutPronunciation() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0001", x: 0.150, y: 0.760),
            token("credit card", x: 0.150, y: 0.738),
            token("신용 카드", x: 0.150, y: 0.714)
        ])

        XCTAssertEqual(output, "0001-credit card-신용 카드")
    }

    func testPreservesShortSimilarMultiwordHeadword() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0001", x: 0.150, y: 0.760),
            token("in line", x: 0.150, y: 0.738),
            token("일렬로", x: 0.150, y: 0.714)
        ])

        XCTAssertEqual(output, "0001-in line-일렬로")
    }

    func testUsesNearestMeaningLineInsteadOfMixingAdjacentRows() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0001", x: 0.150, y: 0.760),
            token("categorically", x: 0.150, y: 0.738),
            token("절대적으로, 명확히", x: 0.150, y: 0.714),
            token("0002", x: 0.150, y: 0.680),
            token("obsolete", x: 0.150, y: 0.658),
            token("구식의, 한물 간", x: 0.150, y: 0.634)
        ])

        XCTAssertEqual(
            output,
            """
            0001-categorically-절대적으로, 명확히
            0002-obsolete-구식의, 한물 간
            """
        )
    }

    func testPreservesWrappedMeaningLinesWithinSameVocabularyRow() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0001", x: 0.150, y: 0.760),
            token("categorically", x: 0.150, y: 0.738),
            token("절대적으로, 단정적으로", x: 0.150, y: 0.714),
            token("명확히", x: 0.150, y: 0.694),
            token("0002", x: 0.150, y: 0.660),
            token("obsolete", x: 0.150, y: 0.638),
            token("구식의", x: 0.150, y: 0.614)
        ])

        XCTAssertEqual(
            output,
            """
            0001-categorically-절대적으로, 단정적으로 명확히
            0002-obsolete-구식의
            """
        )
    }

    func testMissingMiddleNumberDoesNotMergeItsMeaningIntoPreviousRow() throws {
        let result = try OCRVocabularyFormatter.formatPagesWithDiagnostics([[
            token("0001", x: 0.150, y: 0.760),
            token("first", x: 0.150, y: 0.738),
            token("첫째", x: 0.150, y: 0.714),
            token("second", x: 0.150, y: 0.658),
            token("둘째", x: 0.150, y: 0.634),
            token("0003", x: 0.150, y: 0.600),
            token("third", x: 0.150, y: 0.578),
            token("셋째", x: 0.150, y: 0.554),
            token("0004", x: 0.150, y: 0.520),
            token("fourth", x: 0.150, y: 0.498),
            token("넷째", x: 0.150, y: 0.474)
        ]])

        XCTAssertEqual(
            result.text,
            """
            0001-first-첫째
            0003-third-셋째
            0004-fourth-넷째
            """
        )
        XCTAssertEqual(result.suspectedMissingNumbers, ["0002"])
    }

    func testReportsRecognizedNumberWhenItsVocabularyRowCannotBeCompleted() throws {
        let result = try OCRVocabularyFormatter.formatPagesWithDiagnostics([[
            token("0001", x: 0.150, y: 0.760),
            token("categorically", x: 0.150, y: 0.738),
            token("절대적으로, 명확히", x: 0.150, y: 0.714),
            token("0002", x: 0.150, y: 0.680),
            token("obsolete", x: 0.150, y: 0.658)
        ]])

        XCTAssertEqual(result.text, "0001-categorically-절대적으로, 명확히")
        XCTAssertEqual(result.suspectedMissingNumbers, ["0002"])
    }

    func testReportsMissingFirstAndLastRowsOnCompleteDayPage() throws {
        var tokens = vocabularyPage(start: 1, rowCount: 20)
        tokens.append(token("DAY01", x: 0.500, y: 0.850))
        tokens.removeAll { token in
            (token.boundingBox.midX < 0.5 && token.boundingBox.midY > 0.71) ||
            (token.boundingBox.midX > 0.5 && token.boundingBox.midY < 0.21)
        }

        let result = try OCRVocabularyFormatter.formatPagesWithDiagnostics([tokens])

        XCTAssertEqual(result.suspectedMissingNumbers, ["0001", "0020"])
    }

    func testReportsThreeLeadingRowsMissingFromOneDayPageColumn() throws {
        var tokens = vocabularyPage(start: 1, rowCount: 20)
        tokens.append(token("DAY01", x: 0.500, y: 0.850))
        tokens.removeAll { token in
            token.boundingBox.midX < 0.5 && token.boundingBox.midY > 0.58
        }

        let result = try OCRVocabularyFormatter.formatPagesWithDiagnostics([tokens])

        XCTAssertEqual(result.suspectedMissingNumbers, ["0001", "0002", "0003"])
    }

    func testManualCorrectionResolvesReportedOCRMissingNumber() throws {
        let result = OCRVocabularyFormattingResult(
            text: "0001-first-첫째",
            suspectedMissingNumbers: ["0002"]
        )

        XCTAssertEqual(result.unresolvedMissingNumbers(in: result.text), ["0002"])
        XCTAssertEqual(
            result.unresolvedMissingNumbers(
                in: """
                0001-first-첫째
                0002-second-둘째
                """
            ),
            []
        )
    }

    func testRecognizesRestartedNumberingReferenceImage() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "restarted-numbering-layout",
                withExtension: "png",
                subdirectory: "Fixtures"
            ) ?? Bundle(for: Self.self).url(
                forResource: "restarted-numbering-layout",
                withExtension: "png"
            )
        )
        let tokens = try OCRTextRecognizer.recognizeTokens(from: fixtureURL)
        let result = try OCRVocabularyFormatter.formatPagesWithDiagnostics([tokens])
        let output = result.text

        XCTAssertEqual(
            output,
            """
            0001-categorically-절대적으로, 단정적으로, 명확히
            0002-obsolete-구식의, 한물 간, 시대에 뒤떨어진
            0003-evaporation-증발, 소멸, 소산
            0004-impair-(힘·가치·건강 등을) 손상시키다, 악화시키다, 해치다
            0005-prestige-명성, 위신, 위신[명망] 있는, 일류의, 고급의
            0006-general election-총선
            0007-crooked-구부러진, 부정직한
            0008-detain-억류하다, 구류하다, 감금하다
            0009-fair-minded-(판단 등이) 공평한, 공정한, 편견이 없는
            0010-topmost-가장 높은, 최고의
            0011-insinuate-암시하다, 돌려서 말하다
            0012-tentative-잠정적인, 시험적인, 임시의, 머뭇거리는
            0013-psychiatric-정신의학의, 정신과의
            0014-sensual-관능적인, 육감적인, 육체적인
            0015-ability-할수있음, 능력
            0016-carnal-육체의, 세속적인
            0017-inexperienced-경험이 없는, 미숙한, 서투른
            0018-jealousy-질투(심)
            0019-miserly-구두쇠의, 인색한, 욕심많은, (양·금액 등이) 매우 적은
            0020-embryonic-배에 관한, 태아의, 미발달의, 미숙한
            """
        )
        XCTAssertTrue(result.suspectedMissingNumbers.isEmpty)
    }

    func testMissingNumberAnalysisTreatsNumberRestartAsNewSequence() {
        let missing = IntakeNumberSequenceAnalyzer.missingNumbers(
            in: """
            0098-old-기존
            0100-gap-누락 있음
            0001-new-새 항목
            0003-next-다음 항목
            """
        )

        XCTAssertEqual(missing, ["0099", "0002"])
    }

    func testNumberPrefixesSupportResolvingOCRMissingWarningsAfterManualCorrection() {
        let prefixes = IntakeNumberSequenceAnalyzer.numberPrefixes(
            in: """
            0001-first-첫째
            malformed
            0002-second-둘째
            """
        )

        XCTAssertEqual(prefixes, ["0001", "0002"])
    }

    func testRecoversNoisyNumbersAndLooserRowAlignment() throws {
        let output = try OCRVocabularyFormatter.format([
            token("O501.", x: 0.150, y: 0.714),
            token("well-known", x: 0.231, y: 0.738),
            token("널리", x: 0.246, y: 0.686),
            token("알려진", x: 0.306, y: 0.684),
            token("[wel]", x: 0.462, y: 0.744),
            token("0511", x: 0.528, y: 0.713),
            token("joke", x: 0.615, y: 0.731),
            token("농담", x: 0.622, y: 0.688)
        ])

        XCTAssertEqual(
            output,
            """
            0501-well-known-널리 알려진
            0511-joke-농담
            """
        )
    }

    func testRecoversRowWhenMeaningTokenIsVerticallyOffset() throws {
        let output = try OCRVocabularyFormatter.format([
            token("O501", x: 0.150, y: 0.714, height: 0.020),
            token("pill", x: 0.231, y: 0.729),
            token("알약", x: 0.227, y: 0.758),
            token("[pil]", x: 0.462, y: 0.734),
            token("0502", x: 0.150, y: 0.614),
            token("math", x: 0.231, y: 0.629),
            token("수학", x: 0.227, y: 0.615)
        ])

        XCTAssertEqual(
            output,
            """
            0501-pill-알약
            0502-math-수학
            """
        )
    }

    func testIgnoresDuplicateNumberCandidatesAndKeepsFirstVocabularyRow() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0501", x: 0.150, y: 0.714),
            token("0501", x: 0.462, y: 0.734),
            token("pill", x: 0.231, y: 0.729),
            token("알약", x: 0.227, y: 0.715)
        ])

        XCTAssertEqual(output, "0501-pill-알약")
    }

    func testInvalidDuplicateNumberCandidateDoesNotHideValidVocabularyRow() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0501", x: 0.462, y: 0.734),
            token("[pil]", x: 0.470, y: 0.734),
            token("0501", x: 0.150, y: 0.714),
            token("pill", x: 0.231, y: 0.729),
            token("알약", x: 0.227, y: 0.715)
        ])

        XCTAssertEqual(output, "0501-pill-알약")
    }

    func testHundredRowFixtureRecoversAtLeastNinetyEightRows() throws {
        let output = try OCRVocabularyFormatter.formatPages([
            vocabularyPage(start: 501, rowCount: 20),
            vocabularyPage(start: 521, rowCount: 20),
            vocabularyPage(start: 541, rowCount: 20),
            vocabularyPage(start: 561, rowCount: 20),
            vocabularyPage(start: 581, rowCount: 20)
        ])
        let rows = output.split(separator: "\n")

        XCTAssertGreaterThanOrEqual(rows.count, 98)
        XCTAssertTrue(rows.contains("0501-word-뜻501"), output)
        XCTAssertTrue(rows.contains("0600-word-뜻600"), output)
    }

    func testDuplicateNumberCandidateDoesNotBlockBetterVocabularyRow() throws {
        let output = try OCRVocabularyFormatter.format([
            token("0501", x: 0.150, y: 0.650),
            token("noise", x: 0.340, y: 0.680),
            token("잡음", x: 0.390, y: 0.620),
            token("0501", x: 0.150, y: 0.714),
            token("pill", x: 0.231, y: 0.729),
            token("알약", x: 0.227, y: 0.715)
        ])

        XCTAssertEqual(output, "0501-pill-알약")
    }

    private func token(_ text: String, x: CGFloat, y: CGFloat, height: CGFloat = 0.015) -> OCRTextToken {
        OCRTextToken(text: text, boundingBox: CGRect(x: x, y: y, width: 0.05, height: height))
    }

    private func vocabularyPage(start: Int, rowCount: Int) -> [OCRTextToken] {
        (0..<rowCount).flatMap { offset -> [OCRTextToken] in
            let number = start + offset
            let row = offset % 10
            let isRightColumn = offset >= 10
            let baseX: CGFloat = isRightColumn ? 0.528 : 0.150
            let termX: CGFloat = isRightColumn ? 0.615 : 0.231
            let meaningX: CGFloat = isRightColumn ? 0.622 : 0.227
            let y = CGFloat(0.730 - Double(row) * 0.062)
            let noisyNumber = number % 10 == 1
                ? String(format: "O%03d.", number % 1000)
                : String(format: "%04d", number)
            let meaningY = y - CGFloat(number % 4 == 0 ? 0.030 : 0.014)
            return [
                token(noisyNumber, x: baseX, y: y, height: 0.018),
                token("word", x: termX, y: y + 0.015),
                token("뜻\(number)", x: meaningX, y: meaningY),
                token("[w\(number)]", x: isRightColumn ? 0.825 : 0.462, y: y + 0.015)
            ]
        }
    }

}
