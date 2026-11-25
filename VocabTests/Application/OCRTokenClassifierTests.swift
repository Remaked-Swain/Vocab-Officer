import XCTest
@testable import Vocab

final class OCRTokenClassifierTests: XCTestCase {
    func testSeparateAsciiTokenWithTheSameConsonantsIsPronunciation() {
        XCTAssertTrue(OCRTokenClassifier.isUnbracketedPronunciation("dred", of: "dread"))
        XCTAssertTrue(OCRTokenClassifier.isUnbracketedPronunciation("haid", of: "hide"))
        XCTAssertTrue(OCRTokenClassifier.isUnbracketedPronunciation("doudou", of: "dodo"))
        XCTAssertTrue(OCRTokenClassifier.isUnbracketedPronunciation("kændid", of: "candid"))
        XCTAssertTrue(OCRTokenClassifier.isUnbracketedPronunciation("sordid", of: "sordid"))
        XCTAssertTrue(OCRTokenClassifier.isUnbracketedPronunciation("dizmal", of: "dismal"))
        XCTAssertFalse(OCRTokenClassifier.isUnbracketedPronunciation("ad", of: "odd"))
        XCTAssertFalse(OCRTokenClassifier.isUnbracketedPronunciation("card", of: "credit"))
        XCTAssertFalse(OCRTokenClassifier.isUnbracketedPronunciation("ni d", of: "need"))
    }

    func testStripsPronunciationCarryingIPAMarks() {
        XCTAssertEqual(OCRTokenClassifier.englishTerm(from: "adopt ədɑ́pt"), "adopt")
        XCTAssertEqual(OCRTokenClassifier.englishTerm(from: "need ni:d"), "need")
        XCTAssertNil(OCRTokenClassifier.englishTerm(from: "[dred]"))
        XCTAssertNil(OCRTokenClassifier.englishTerm(from: "dæd"))
    }

    func testKeepsMultiwordAndRepeatedWordHeadwordsReadAsOneToken() {
        let phrases = [
            "credit card", "in line", "in on", "make inroads", "one on one", "home made", "set up",
            "hip hop", "ping pong", "zig zag", "flip flop", "tip top", "so so", "bye bye"
        ]
        for phrase in phrases {
            XCTAssertEqual(OCRTokenClassifier.englishTerm(from: phrase), phrase)
        }
    }

    func testConsonantSkeletonFoldsSpellingVariantsAndKeepsRepeatedSyllables() {
        XCTAssertEqual(OCRTokenClassifier.consonantSkeleton("candid"), "kndd")
        XCTAssertEqual(OCRTokenClassifier.consonantSkeleton("kændid"), "kndd")
        XCTAssertEqual(OCRTokenClassifier.consonantSkeleton("dodo"), "dd")
        XCTAssertEqual(OCRTokenClassifier.consonantSkeleton("phlox"), "flks")
        XCTAssertEqual(OCRTokenClassifier.consonantSkeleton("odd"), "d")
    }

    func testBracketedPronunciationReadAsHangulIsNotAMeaning() {
        XCTAssertFalse(OCRTokenClassifier.isMeaningToken("[d시]"))
        XCTAssertTrue(OCRTokenClassifier.isMeaningToken("위신[명망] 있는"))
        XCTAssertTrue(OCRTokenClassifier.isMeaningToken("[법률] 소송"))
        XCTAssertTrue(OCRTokenClassifier.isMeaningToken("(힘·가치) 손상시키다"))
    }
}
