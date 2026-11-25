import CoreGraphics
import XCTest
@testable import Vocab

final class OCRUnnumberedLayoutTests: XCTestCase {
    func testPairsSideBySideRowsColumnByColumnAsTabSeparatedDrafts() throws {
        let output = try OCRVocabularyFormatter.format([
            token("candid", x: 0.55, y: 0.80, width: 0.08),
            token("솔직한", x: 0.70, y: 0.80),
            token("adopt", x: 0.05, y: 0.80, width: 0.08),
            token("채택하다", x: 0.20, y: 0.80, width: 0.10),
            token("dread", x: 0.05, y: 0.75, width: 0.08),
            token("두려움", x: 0.20, y: 0.75),
            token("daunt", x: 0.55, y: 0.75, width: 0.08),
            token("겁먹게 하다", x: 0.70, y: 0.75, width: 0.10)
        ])

        XCTAssertEqual(
            output,
            """
            adopt\t채택하다
            dread\t두려움
            candid\t솔직한
            daunt\t겁먹게 하다
            """
        )
    }

    func testStackedCardsKeepWrappedMeaningLinesAndSkipPronunciationTokens() throws {
        let output = try OCRVocabularyFormatter.format([
            token("impair", x: 0.05, y: 0.80, width: 0.08),
            token("[impéər]", x: 0.14, y: 0.80, width: 0.08),
            token("손상시키다,", x: 0.05, y: 0.775, width: 0.10),
            token("악화시키다", x: 0.05, y: 0.755, width: 0.10),
            token("hide", x: 0.05, y: 0.70, width: 0.06),
            // An unbracketed transcription Vision read as a separate word.
            token("haid", x: 0.12, y: 0.70, width: 0.05),
            token("숨기다", x: 0.05, y: 0.675)
        ])

        XCTAssertEqual(
            output,
            """
            impair\t손상시키다, 악화시키다
            hide\t숨기다
            """
        )
    }

    func testSplitsOneLineEntryAtTheMeaningAndKeepsItsLeadingParenthesis() throws {
        let output = try OCRVocabularyFormatter.format([
            token("impair impéər - (힘·가치) 손상시키다", x: 0.05, y: 0.80, width: 0.40),
            token("fair-minded: 공정한", x: 0.05, y: 0.75, width: 0.30)
        ])

        XCTAssertEqual(
            output,
            """
            impair\t(힘·가치) 손상시키다
            fair-minded\t공정한
            """
        )
    }

    func testIgnoresHeadersAndLatinTokensWithoutMeanings() throws {
        let output = try OCRVocabularyFormatter.format([
            token("DAY 01", x: 0.05, y: 0.90, width: 0.08),
            token("Vocabulary", x: 0.40, y: 0.90, width: 0.15),
            token("adopt", x: 0.05, y: 0.80, width: 0.08),
            token("채택하다", x: 0.20, y: 0.80, width: 0.10)
        ])

        XCTAssertEqual(output, "adopt\t채택하다")
    }

    func testNumberedPagesAndUnnumberedPagesKeepSelectedPageOrder() throws {
        let result = try OCRVocabularyFormatter.formatPagesWithDiagnostics([
            [
                token("adopt", x: 0.05, y: 0.80, width: 0.08),
                token("채택하다", x: 0.20, y: 0.80, width: 0.10)
            ],
            [
                token("0501", x: 0.150, y: 0.714),
                token("pill", x: 0.231, y: 0.729),
                token("알약", x: 0.227, y: 0.715)
            ]
        ])

        XCTAssertEqual(result.text, "adopt\t채택하다\n0501-pill-알약")
        XCTAssertTrue(result.suspectedMissingNumbers.isEmpty)
    }

    func testExplainsWhichHalfOfTheVocabularyIsMissing() {
        XCTAssertThrowsError(try OCRVocabularyFormatter.format([token("채택하다", x: 0.2, y: 0.8)])) {
            XCTAssertEqual($0 as? OCRVocabularyFormatError, .noHeadwords)
        }
        XCTAssertThrowsError(try OCRVocabularyFormatter.format([token("adopt", x: 0.2, y: 0.8)])) {
            XCTAssertEqual($0 as? OCRVocabularyFormatError, .noMeanings)
        }
        // A meaning far below and right of the only headword pairs with nothing.
        XCTAssertThrowsError(try OCRVocabularyFormatter.format([
            token("adopt", x: 0.05, y: 0.80, width: 0.08),
            token("채택하다", x: 0.60, y: 0.30)
        ])) {
            XCTAssertEqual($0 as? OCRVocabularyFormatError, .noVocabularyRows)
        }
        for error in [OCRVocabularyFormatError.noHeadwords, .noMeanings, .noVocabularyRows] {
            XCTAssertTrue(error.errorDescription?.contains("캡쳐") == true || error.errorDescription?.contains("형식") == true)
        }
    }

    private func token(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 0.06,
        height: CGFloat = 0.015
    ) -> OCRTextToken {
        OCRTextToken(text: text, boundingBox: CGRect(x: x, y: y, width: width, height: height))
    }
}
