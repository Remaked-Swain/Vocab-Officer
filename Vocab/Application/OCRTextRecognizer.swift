import Foundation
import ImageIO
import Vision

/// Reads text tokens from a vocabulary image with Vision. Runs synchronously and
/// must be called off the main actor.
enum OCRTextRecognizer {
    static func recognizeTokens(from url: URL) throws -> [OCRTextToken] {
        // A picked file in the macOS sandbox is readable only while its
        // security scope is open; plain file URLs (tests, iOS) return false
        // and need nothing.
        let isAccessingScope = url.startAccessingSecurityScopedResource()
        defer { if isAccessingScope { url.stopAccessingSecurityScopedResource() } }
        guard let cgImage = downsampledCGImage(from: url) else {
            throw FileManager.default.isReadableFile(atPath: url.path)
                ? OCRError.unreadableImage(fileName: url.lastPathComponent)
                : OCRError.inaccessibleImage(fileName: url.lastPathComponent)
        }
        let fullPage = try recognizeRegion(OCRRecognitionPlan.fullPage, in: cgImage)
        guard OCRRecognitionPlan.needsTiledRecognition(fullPage) else {
            return fullPage.lines.map(\.token)
        }
        var voters = [fullPage.lines]
        for tile in OCRRecognitionPlan.fallbackTiles {
            // About 26 Vision calls; stop early if the intake was abandoned.
            if Task.isCancelled {
                throw CancellationError()
            }
            let lines = try recognizeRegion(tile.searchRegion, in: cgImage).lines
            voters.append(lines.filter { tile.keeps($0.token.boundingBox) })
        }
        return OCRRecognitionMerger.voted(voters)
    }

    /// One region read twice: the Korean+English model keeps Hangul meanings
    /// exact, and the English-only model replaces its Latin tokens because the
    /// mixed model misreads small Latin glyphs (e.g. `d` as `a`).
    private static func recognizeRegion(_ region: CGRect, in image: CGImage) throws -> RegionRecognition {
        let mixed = try recognizeUpright(
            region,
            in: image,
            languages: ["ko-KR", "en-US"],
            // On the macOS 27 revision-3 model, correction is what keeps Hangul
            // meanings exact (e.g. 머뭇 vs 머붓).
            usesLanguageCorrection: true
        )
        let latin = try recognizeUpright(
            region,
            in: image,
            languages: ["en-US"],
            // Without correction, IPA marks survive, which lets the formatter
            // tell pronunciation from headwords; headwords read exactly either way.
            usesLanguageCorrection: false
        )
        return RegionRecognition(
            lines: OCRRecognitionMerger.replacingLatinTokens(in: mixed.lines, with: latin.lines),
            hadInvertedLines: mixed.hadInvertedLines || latin.hadInvertedLines
        )
    }

    /// Vision guesses page orientation from content and, on sparse pages with
    /// small text, reads some lines rotated 180°. Those lines are detectable by
    /// their reversed baseline and are read again with the orientation flipped.
    private static func recognizeUpright(
        _ region: CGRect,
        in image: CGImage,
        languages: [String],
        usesLanguageCorrection: Bool
    ) throws -> RegionRecognition {
        let upright = try recognize(
            region,
            in: image,
            orientation: .up,
            languages: languages,
            usesLanguageCorrection: usesLanguageCorrection
        )
        guard upright.contains(where: { !$0.isUpright }) else {
            return RegionRecognition(lines: upright, hadInvertedLines: false)
        }
        let flipped = try recognize(
            region,
            in: image,
            orientation: .down,
            languages: languages,
            usesLanguageCorrection: usesLanguageCorrection
        )
        return RegionRecognition(
            lines: OCRRecognitionMerger.uprightUnion(upright, flipped),
            hadInvertedLines: true
        )
    }

    private static func recognize(
        _ region: CGRect,
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        languages: [String],
        usesLanguageCorrection: Bool
    ) throws -> [RecognizedLine] {
        let isFlipped = orientation == .down
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = usesLanguageCorrection
        request.regionOfInterest = isFlipped ? flipped(region) : region
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try handler.perform([request])
        let roi = request.regionOfInterest
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Observation points are normalized to the region in the oriented
            // image; map them back to upright full-image coordinates.
            let corners = [
                observation.topLeft,
                observation.topRight,
                observation.bottomLeft,
                observation.bottomRight
            ].map { point -> CGPoint in
                let oriented = CGPoint(
                    x: roi.minX + point.x * roi.width,
                    y: roi.minY + point.y * roi.height
                )
                return isFlipped ? CGPoint(x: 1 - oriented.x, y: 1 - oriented.y) : oriented
            }
            let xs = corners.map(\.x)
            let ys = corners.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
                return nil
            }
            return RecognizedLine(
                token: OCRTextToken(
                    text: text,
                    boundingBox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                ),
                confidence: candidate.confidence,
                isUpright: corners[1].x > corners[0].x
            )
        }
    }

    private static func flipped(_ region: CGRect) -> CGRect {
        CGRect(x: 1 - region.maxX, y: 1 - region.maxY, width: region.width, height: region.height)
    }

    private static func downsampledCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Recall depends on text height relative to the page, not on pixel
            // count, so a larger limit only costs memory and time.
            kCGImageSourceThumbnailMaxPixelSize: 2_400
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A recognized line in upright, normalized full-image coordinates.
struct RecognizedLine {
    let token: OCRTextToken
    let confidence: Float
    /// False when Vision read the line rotated 180°, i.e. its text is garbage.
    let isUpright: Bool
}

/// Upright lines of one region, and whether Vision misjudged its orientation,
/// which marks the region's detection as unreliable even after recovery.
struct RegionRecognition {
    let lines: [RecognizedLine]
    let hadInvertedLines: Bool
}

/// When a page needs tiled recognition and which tiles it uses.
enum OCRRecognitionPlan {
    static let fullPage = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Vision's text detector drops lines whose height is under about 1% of
    /// the image. Measured on rendered pages: a median line height ≤ 0.0075
    /// lost most lines, 0.0102 lost some or none, ≥ 0.0116 read every line.
    static let minimumReliableLineHeight: CGFloat = 0.011

    /// Tiles share this much of the neighbouring tile so a line cut by one
    /// tile's edge lies whole inside the other.
    static let tileOverlap: CGFloat = 0.03

    /// Single tilings each lose different lines where their edges fall; voting
    /// across several recovered 37–40 of 40 headwords on small-text pages.
    static let fallbackLayouts: [(rows: Int, columns: Int)] = [(2, 1), (2, 2), (3, 2)]

    static var fallbackTiles: [OCRRecognitionTile] {
        fallbackLayouts.flatMap { layout in
            (0..<layout.rows).flatMap { row in
                (0..<layout.columns).map { column in
                    OCRRecognitionTile(row: row, column: column, rows: layout.rows, columns: layout.columns)
                }
            }
        }
    }

    /// Every meaning has a headword, so far fewer Latin lines than Hangul
    /// lines means Vision dropped headword lines; it does so when a headword
    /// sits about one line above its meaning, and tiles read them again.
    static let minimumLatinToHangulLineRatio = 0.6

    static func needsTiledRecognition(_ page: RegionRecognition) -> Bool {
        if page.hadInvertedLines {
            return true
        }
        let heights = page.lines.map(\.token.boundingBox.height).sorted()
        guard !heights.isEmpty else { return false }
        if heights[heights.count / 2] < minimumReliableLineHeight {
            return true
        }
        let hangulLineCount = page.lines.filter { OCRTokenClassifier.containsHangul($0.token.text) }.count
        let latinLineCount = page.lines.filter { line in
            !OCRTokenClassifier.containsHangul(line.token.text) &&
                line.token.text.contains { $0.isASCII && $0.isLetter }
        }.count
        return hangulLineCount >= 6 &&
            Double(latinLineCount) < Double(hangulLineCount) * minimumLatinToHangulLineRatio
    }
}

struct OCRRecognitionTile {
    /// The tile's own share of the page; a line belongs to the one tile whose
    /// core contains its center, so overlapping tiles never both report it.
    let core: CGRect
    let searchRegion: CGRect

    init(row: Int, column: Int, rows: Int, columns: Int) {
        let width = 1 / CGFloat(columns)
        let height = 1 / CGFloat(rows)
        core = CGRect(x: CGFloat(column) * width, y: CGFloat(row) * height, width: width, height: height)
        searchRegion = core
            .insetBy(
                dx: columns > 1 ? -OCRRecognitionPlan.tileOverlap : 0,
                dy: rows > 1 ? -OCRRecognitionPlan.tileOverlap : 0
            )
            .intersection(OCRRecognitionPlan.fullPage)
    }

    /// How close to an inner edge of the search region a line may end before
    /// it counts as cut there.
    static let cutTolerance: CGFloat = 0.004

    /// A line this tile reports: owned by it, and not cut by one of its inner
    /// edges. Vision crops to the search region, so a line crossing an inner
    /// edge comes back as a fragment that would out-vote the whole line;
    /// such lines come only from tilings whose edges miss them.
    func keeps(_ box: CGRect) -> Bool {
        owns(box) && !isCutByInnerEdge(box)
    }

    func isCutByInnerEdge(_ box: CGRect) -> Bool {
        let tolerance = Self.cutTolerance
        return (searchRegion.minX > 0 && box.minX <= searchRegion.minX + tolerance) ||
            (searchRegion.maxX < 1 && box.maxX >= searchRegion.maxX - tolerance) ||
            (searchRegion.minY > 0 && box.minY <= searchRegion.minY + tolerance) ||
            (searchRegion.maxY < 1 && box.maxY >= searchRegion.maxY - tolerance)
    }

    func owns(_ box: CGRect) -> Bool {
        let center = CGPoint(x: box.midX, y: box.midY)
        // Include the far page edges, which `contains` treats as outside.
        return center.x >= core.minX && center.y >= core.minY &&
            (center.x < core.maxX || core.maxX >= 1) &&
            (center.y < core.maxY || core.maxY >= 1)
    }
}

/// Pure merging rules for Vision passes; kept apart from Vision for testing.
enum OCRRecognitionMerger {
    /// Hangul lines come from the mixed pass. English-pass lines replace the
    /// mixed pass's Latin lines they overlap; an English-pass line over a
    /// Hangul line is a misread of Korean and is dropped, and a mixed Latin
    /// line the English pass missed is kept.
    static func replacingLatinTokens(
        in mixed: [RecognizedLine],
        with latin: [RecognizedLine]
    ) -> [RecognizedLine] {
        let hangul = mixed.filter { containsHangul($0.token.text) }
        let mixedLatin = mixed.filter { !containsHangul($0.token.text) }
        let keptLatin = latin.filter { line in
            !containsHangul(line.token.text) &&
                !hangul.contains { overlapRatio(line.token.boundingBox, $0.token.boundingBox) > 0.3 }
        }
        let unmatchedMixedLatin = mixedLatin.filter { line in
            !keptLatin.contains { overlapRatio(line.token.boundingBox, $0.token.boundingBox) > 0.3 }
        }
        return hangul + keptLatin + unmatchedMixedLatin
    }

    /// Upright lines of both orientations, without reading a line twice.
    static func uprightUnion(_ first: [RecognizedLine], _ second: [RecognizedLine]) -> [RecognizedLine] {
        var result = first.filter(\.isUpright)
        for line in second where line.isUpright {
            let isDuplicate = result.contains {
                overlapRatio(line.token.boundingBox, $0.token.boundingBox) > 0.5
            }
            if !isDuplicate {
                result.append(line)
            }
        }
        return result
    }

    /// Groups lines that cover the same span across passes and keeps, per
    /// group, the text most passes agree on (ties go to the higher total
    /// confidence). Grouping is mutual, against the larger box: one pass's
    /// `need [ni:d]` must not swallow another pass's separate `need` and
    /// `[ni:d]`, or the bracketed half could win and drop the headword. The
    /// same text on overlapping boxes of different sizes is one reading: a
    /// duplicated printed number would otherwise collapse its own row.
    static func voted(_ passes: [[RecognizedLine]]) -> [OCRTextToken] {
        var groups: [[RecognizedLine]] = []
        for line in passes.joined() {
            if let index = groups.firstIndex(where: { group in
                let anchor = group[0].token
                return mutualOverlapRatio(anchor.boundingBox, line.token.boundingBox) > 0.6 ||
                    (anchor.text == line.token.text && overlapRatio(anchor.boundingBox, line.token.boundingBox) > 0.5)
            }) {
                groups[index].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.compactMap { group in
            var tallies: [String: (count: Int, confidence: Float)] = [:]
            for line in group {
                let tally = tallies[line.token.text] ?? (0, 0)
                tallies[line.token.text] = (tally.count + 1, tally.confidence + line.confidence)
            }
            guard let winner = tallies.max(by: {
                ($0.value.count, $0.value.confidence) < ($1.value.count, $1.value.confidence)
            }) else {
                return nil
            }
            let box = group.first { $0.token.text == winner.key }?.token.boundingBox ?? group[0].token.boundingBox
            return OCRTextToken(text: winner.key, boundingBox: box)
        }
    }

    /// Intersection area relative to the smaller box.
    static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        intersectionArea(lhs, rhs) / max(min(area(lhs), area(rhs)), .leastNonzeroMagnitude)
    }

    /// Intersection area relative to the larger box.
    static func mutualOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        intersectionArea(lhs, rhs) / max(max(area(lhs), area(rhs)), .leastNonzeroMagnitude)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : area(intersection)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func containsHangul(_ value: String) -> Bool {
        OCRTokenClassifier.containsHangul(value)
    }
}

enum OCRError: LocalizedError, Equatable {
    /// The file could not be opened: no sandbox access, or it moved.
    case inaccessibleImage(fileName: String)
    /// The file opened but is not an image the system can decode.
    case unreadableImage(fileName: String)
    case noText

    var errorDescription: String? {
        switch self {
        case .inaccessibleImage(let fileName):
            "'\(fileName)' 파일을 열 수 없습니다. 파일이 이동·삭제되었거나 접근 권한이 없습니다. 이미지를 다시 선택하세요."
        case .unreadableImage(let fileName):
            "'\(fileName)'을(를) 이미지로 읽을 수 없습니다. JPEG, PNG, HEIC 같은 이미지 파일인지 확인하세요."
        case .noText:
            "선택한 이미지에서 글자를 찾지 못했습니다. 단어가 선명하게 보이는 이미지를 선택하세요."
        }
    }
}
