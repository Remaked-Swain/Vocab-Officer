import CoreGraphics
import XCTest
@testable import Vocab

final class OCRTextRecognizerTests: XCTestCase {
    // MARK: Merging passes

    func testEnglishPassReplacesOverlappingLatinTokensAndKeepsHangulFromMixedPass() {
        let mixed = [
            line("aitch [dity", x: 0.10, y: 0.80, width: 0.12),
            line("도랑", x: 0.10, y: 0.77),
            line("0037", x: 0.02, y: 0.80)
        ]
        let latin = [
            line("ditch [ditf]", x: 0.10, y: 0.80, width: 0.12),
            // The English model's reading of Hangul is garbage and must not win.
            line("Eㅌ", x: 0.10, y: 0.77)
        ]

        let merged = OCRRecognitionMerger.replacingLatinTokens(in: mixed, with: latin).map(\.token.text)

        XCTAssertEqual(Set(merged), ["도랑", "ditch [ditf]", "0037"])
    }

    func testOrientationRecoveryKeepsOnlyUprightLinesOnce() {
        let upright = [
            line("0001", x: 0.10, y: 0.80),
            line("0P00", x: 0.10, y: 0.20, isUpright: false)
        ]
        let flipped = [
            line("0001", x: 0.10, y: 0.80),
            line("0040", x: 0.10, y: 0.20),
            line("adopt", x: 0.30, y: 0.20, isUpright: false)
        ]

        let union = OCRRecognitionMerger.uprightUnion(upright, flipped).map(\.token.text)

        XCTAssertEqual(union, ["0001", "0040"])
    }

    func testVotingKeepsMajorityReadingAndDoesNotLetAWideLineSwallowItsParts() {
        let passes = [
            [line("hide", x: 0.10, y: 0.50), line("need [ni: d]", x: 0.10, y: 0.30, width: 0.12)],
            [line("hides", x: 0.10, y: 0.50), line("need", x: 0.10, y: 0.30), line("[ni: d]", x: 0.17, y: 0.30)],
            [line("hide", x: 0.10, y: 0.50), line("[ni: d]", x: 0.17, y: 0.30)]
        ]

        let texts = OCRRecognitionMerger.voted(passes).map(\.text)

        XCTAssertTrue(texts.contains("hide"))
        XCTAssertFalse(texts.contains("hides"))
        XCTAssertTrue(texts.contains("need"), "the headword survives beside its bracketed pronunciation")
    }

    // MARK: Recognition plan

    func testTiledRecognitionRunsOnlyForSmallTextOrMisjudgedOrientation() {
        let readable = (0..<9).map { line("w\($0)", x: 0.1, y: 0.1 * Double($0), height: 0.013) }
        let tiny = (0..<9).map { line("w\($0)", x: 0.1, y: 0.1 * Double($0), height: 0.007) }

        XCTAssertFalse(OCRRecognitionPlan.needsTiledRecognition(RegionRecognition(lines: readable, hadInvertedLines: false)))
        XCTAssertTrue(OCRRecognitionPlan.needsTiledRecognition(RegionRecognition(lines: tiny, hadInvertedLines: false)))
        XCTAssertTrue(OCRRecognitionPlan.needsTiledRecognition(RegionRecognition(lines: readable, hadInvertedLines: true)))
        XCTAssertFalse(OCRRecognitionPlan.needsTiledRecognition(RegionRecognition(lines: [], hadInvertedLines: false)))
    }

    func testTiledRecognitionRunsWhenMostMeaningsLackAHeadwordLine() {
        let meanings = (0..<10).map { line("뜻\($0)", x: 0.1, y: 0.08 * Double($0), height: 0.013) }
        let fewHeadwords = (0..<3).map { line("word\($0)", x: 0.1, y: 0.08 * Double($0) + 0.03, height: 0.013) }
        let allHeadwords = (0..<10).map { line("word\($0)", x: 0.1, y: 0.08 * Double($0) + 0.03, height: 0.013) }

        XCTAssertTrue(OCRRecognitionPlan.needsTiledRecognition(
            RegionRecognition(lines: meanings + fewHeadwords, hadInvertedLines: false)
        ))
        XCTAssertFalse(OCRRecognitionPlan.needsTiledRecognition(
            RegionRecognition(lines: meanings + allHeadwords, hadInvertedLines: false)
        ))
    }

    func testEachLineBelongsToExactlyOneTileOfEveryLayoutIncludingPageEdges() {
        let boxes = [
            CGRect(x: 0.49, y: 0.49, width: 0.02, height: 0.02),
            CGRect(x: 0.98, y: 0.98, width: 0.02, height: 0.02),
            CGRect(x: 0, y: 0, width: 0.02, height: 0.02),
            CGRect(x: 0.30, y: 0.66, width: 0.10, height: 0.02)
        ]
        for layout in OCRRecognitionPlan.fallbackLayouts {
            let tiles = OCRRecognitionPlan.fallbackTiles.filter {
                $0.core.width == 1 / CGFloat(layout.columns) && $0.core.height == 1 / CGFloat(layout.rows)
            }
            XCTAssertEqual(tiles.count, layout.rows * layout.columns)
            for box in boxes {
                XCTAssertEqual(tiles.filter { $0.owns(box) }.count, 1, "\(layout) \(box)")
                XCTAssertTrue(tiles.contains { $0.searchRegion.contains(box) && $0.owns(box) }, "\(layout) \(box)")
            }
        }
    }

    func testTileDropsLinesCutByItsInnerEdgesButKeepsLinesAtThePageBorder() throws {
        // Left tile of the top row in the 2×2 layout: inner edges at x 0.53, y 0.47.
        let tile = OCRRecognitionTile(row: 1, column: 0, rows: 2, columns: 2)

        let cutAtMidline = CGRect(x: 0.40, y: 0.80, width: 0.13, height: 0.01)
        let wholeInside = CGRect(x: 0.20, y: 0.80, width: 0.20, height: 0.01)
        let atPageBorder = CGRect(x: 0, y: 0.98, width: 0.10, height: 0.02)
        // Owned (center above 0.5) yet cut by the bottom edge of the region.
        let cutAtRowEdge = CGRect(x: 0.20, y: 0.472, width: 0.10, height: 0.06)
        XCTAssertTrue(tile.owns(cutAtRowEdge))

        XCTAssertFalse(tile.keeps(cutAtMidline))
        XCTAssertTrue(tile.keeps(wholeInside))
        XCTAssertTrue(tile.keeps(atPageBorder))
        XCTAssertFalse(tile.keeps(cutAtRowEdge))
    }

    // MARK: Vision on rendered pages

    /// Long meanings cross the midline where 2×2 and 3×2 tiles are cut; the
    /// fragments those tiles read must not replace the whole line.
    func testTiledRecognitionKeepsLongMeaningsWholeAcrossTileEdges() throws {
        let page = OCRSyntheticPage(
            layout: .longMeanings,
            width: 3_400,
            height: 4_400,
            fontSize: 32,
            words: OCRSyntheticPage.longMeaningWords
        )

        let lines = try recognizedLines(of: page)

        XCTAssertEqual(lines, page.expectedLines)
    }

    func testReadsEveryDHeavyHeadwordExactlyOnNumberedPage() throws {
        let page = OCRSyntheticPage(layout: .numbered, width: 1_700, height: 2_200, fontSize: 24)

        let lines = try recognizedLines(of: page)

        XCTAssertEqual(lines, page.expectedLines)
    }

    func testReadsHeadwordsBesideMeaningsWithoutPrintedNumbers() throws {
        let page = OCRSyntheticPage(layout: .sideBySide, width: 1_700, height: 2_200, fontSize: 24)

        let lines = try recognizedLines(of: page)

        XCTAssertEqual(lines, page.expectedLines)
    }

    func testReadsStackedCardsWithBracketedPronunciationWithoutPrintedNumbers() throws {
        let page = OCRSyntheticPage(layout: .stacked, width: 1_700, height: 2_200, fontSize: 24)

        let lines = try recognizedLines(of: page)

        XCTAssertGreaterThanOrEqual(Set(lines).intersection(page.expectedLines).count, 38, lines.joined(separator: "\n"))
        assertNoPronunciationOrDMisread(lines, page: page)
    }

    /// Text under 1% of the page height used to come back mostly missing or
    /// read upside down; tiled recognition recovers it.
    func testRecoversSmallTextOnLargeSparsePage() throws {
        let page = OCRSyntheticPage(layout: .numbered, width: 3_400, height: 4_400, fontSize: 32)

        let lines = try recognizedLines(of: page)

        XCTAssertGreaterThanOrEqual(Set(lines).intersection(page.expectedLines).count, 38, lines.joined(separator: "\n"))
        assertNoPronunciationOrDMisread(lines, page: page)
    }

    // MARK: Helpers

    private func recognizedLines(of page: OCRSyntheticPage) throws -> [String] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-\(UUID().uuidString).png")
        try page.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let tokens = try OCRTextRecognizer.recognizeTokens(from: url)
        return try OCRVocabularyFormatter.format(tokens)
            .split(separator: "\n")
            .map(String.init)
    }

    /// No headword may carry pronunciation residue or an `a` where the
    /// printed word has `d`; a missing row is tolerated, a wrong one is not.
    private func assertNoPronunciationOrDMisread(
        _ lines: [String],
        page: OCRSyntheticPage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectedTerms = Set(page.words.map(\.term))
        for output in lines {
            let fields = output.split(whereSeparator: { $0 == "\t" || $0 == "-" })
            let term = String(page.layout == .numbered ? fields.dropFirst().first ?? "" : fields.first ?? "")
            XCTAssertTrue(expectedTerms.contains(term), "unexpected headword in \(output)", file: file, line: line)
        }
    }

    private func line(
        _ text: String,
        x: Double,
        y: Double,
        width: Double = 0.05,
        height: Double = 0.015,
        isUpright: Bool = true
    ) -> RecognizedLine {
        RecognizedLine(
            token: OCRTextToken(text: text, boundingBox: CGRect(x: x, y: y, width: width, height: height)),
            confidence: 1,
            isUpright: isUpright
        )
    }
}
