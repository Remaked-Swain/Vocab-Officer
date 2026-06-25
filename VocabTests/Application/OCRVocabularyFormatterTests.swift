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

    func testSortsMultipleImagesByVocabularyNumber() throws {
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
            0501-pill-알약
            10001-master-주인, 명인, 정복하다
            """
        )
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
