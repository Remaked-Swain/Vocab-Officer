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

    private func token(_ text: String, x: CGFloat, y: CGFloat) -> OCRTextToken {
        OCRTextToken(text: text, boundingBox: CGRect(x: x, y: y, width: 0.05, height: 0.015))
    }
}
