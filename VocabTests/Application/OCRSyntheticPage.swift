import AppKit
import CoreText
import Foundation

/// Renders vocabulary pages at test time so OCR recognition is measured on
/// generic dictionary words, never on a captured vocabulary book.
struct OCRSyntheticPage {
    enum Layout {
        /// `0001  headword  [pronunciation]` over the meaning (card blocks).
        case numbered
        /// `headword    meaning` on one line.
        case sideBySide
        /// `headword` over the meaning, no numbers.
        case stacked
        /// One numbered column with long meanings on the headword's line,
        /// starting left of and running across the page's vertical midline.
        case longMeanings
    }

    static let longMeaningWords: [Word] = [
        Word(term: "abandon", pronunciation: "", meaning: "버리다, 포기하다, 단념하다, 그만두다"),
        Word(term: "deliver", pronunciation: "", meaning: "배달하다, 전달하다, 출산하다, 연설하다"),
        Word(term: "design", pronunciation: "", meaning: "설계하다, 디자인하다, 고안하다, 계획하다"),
        Word(term: "maintain", pronunciation: "", meaning: "유지하다, 지속하다, 주장하다, 부양하다"),
        Word(term: "consider", pronunciation: "", meaning: "고려하다, 숙고하다, 여기다, 배려하다"),
        Word(term: "reduce", pronunciation: "", meaning: "줄이다, 축소하다, 낮추다, 진압하다"),
        Word(term: "provide", pronunciation: "", meaning: "제공하다, 공급하다, 대비하다, 규정하다"),
        Word(term: "describe", pronunciation: "", meaning: "묘사하다, 서술하다, 설명하다, 그리다")
    ]

    struct Word {
        let term: String
        let pronunciation: String
        let meaning: String
    }

    /// Two columns of headwords dense in `d`, the glyph the mixed
    /// Korean+English model misread as `a`.
    static let dHeavyWords: [Word] = [
        Word(term: "adopt", pronunciation: "ədɑ́pt", meaning: "채택하다"),
        Word(term: "dread", pronunciation: "dred", meaning: "두려움"),
        Word(term: "deed", pronunciation: "diːd", meaning: "행위"),
        Word(term: "addict", pronunciation: "ǽdikt", meaning: "중독자"),
        Word(term: "dodge", pronunciation: "dɑdʒ", meaning: "피하다"),
        Word(term: "divide", pronunciation: "diváid", meaning: "나누다"),
        Word(term: "model", pronunciation: "mɑ́dl", meaning: "모형"),
        Word(term: "handle", pronunciation: "hǽndl", meaning: "다루다"),
        Word(term: "bold", pronunciation: "bould", meaning: "대담한"),
        Word(term: "dull", pronunciation: "dʌl", meaning: "지루한"),
        Word(term: "denied", pronunciation: "dináid", meaning: "거부된"),
        Word(term: "decade", pronunciation: "dékeid", meaning: "십년"),
        Word(term: "dodo", pronunciation: "dóudou", meaning: "도도새"),
        Word(term: "doubt", pronunciation: "daut", meaning: "의심"),
        Word(term: "odd", pronunciation: "ɑd", meaning: "이상한"),
        Word(term: "bad", pronunciation: "bæd", meaning: "나쁜"),
        Word(term: "need", pronunciation: "niːd", meaning: "필요"),
        Word(term: "idle", pronunciation: "áidl", meaning: "게으른"),
        Word(term: "dad", pronunciation: "dæd", meaning: "아빠"),
        Word(term: "drag", pronunciation: "dræg", meaning: "끌다"),
        Word(term: "candid", pronunciation: "kǽndid", meaning: "솔직한"),
        Word(term: "daunt", pronunciation: "dɔːnt", meaning: "겁먹게 하다"),
        Word(term: "dwindle", pronunciation: "dwíndl", meaning: "줄어들다"),
        Word(term: "diffident", pronunciation: "dífidənt", meaning: "자신 없는"),
        Word(term: "deduce", pronunciation: "didjúːs", meaning: "추론하다"),
        Word(term: "sordid", pronunciation: "sɔ́ːrdid", meaning: "더러운"),
        Word(term: "adorn", pronunciation: "ədɔ́ːrn", meaning: "꾸미다"),
        Word(term: "dismal", pronunciation: "dízməl", meaning: "음울한"),
        Word(term: "deadline", pronunciation: "dédlàin", meaning: "마감"),
        Word(term: "redundant", pronunciation: "ridʌ́ndənt", meaning: "불필요한"),
        Word(term: "abide", pronunciation: "əbáid", meaning: "견디다"),
        Word(term: "hide", pronunciation: "haid", meaning: "숨기다"),
        Word(term: "ride", pronunciation: "raid", meaning: "타다"),
        Word(term: "cede", pronunciation: "siːd", meaning: "양도하다"),
        Word(term: "lead", pronunciation: "liːd", meaning: "이끌다"),
        Word(term: "wade", pronunciation: "weid", meaning: "헤치다"),
        Word(term: "ditch", pronunciation: "ditʃ", meaning: "도랑"),
        Word(term: "dense", pronunciation: "dens", meaning: "빽빽한"),
        Word(term: "dash", pronunciation: "dæʃ", meaning: "돌진"),
        Word(term: "dear", pronunciation: "diər", meaning: "소중한")
    ]

    let layout: Layout
    let width: Int
    let height: Int
    /// Headword font size in pixels; meanings and numbers are slightly smaller.
    let fontSize: CGFloat
    var words: [Word] = OCRSyntheticPage.dHeavyWords

    /// The text a correct reading produces, in reading order.
    var expectedLines: [String] {
        words.enumerated().map { index, word in
            switch layout {
            case .numbered, .longMeanings:
                String(format: "%04d-%@-%@", index + 1, word.term, word.meaning)
            case .sideBySide, .stacked:
                "\(word.term)\t\(word.meaning)"
            }
        }
    }

    func write(to url: URL) throws {
        let image = try render()
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    private func render() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let rowsPerColumn = layout == .longMeanings ? words.count : (words.count + 1) / 2
        let columnWidth = CGFloat(width) / 2
        let top = CGFloat(height) * 0.92
        let rowHeight = fontSize * 3.2
        for (index, word) in words.enumerated() {
            let column = CGFloat(index / rowsPerColumn)
            let row = CGFloat(index % rowsPerColumn)
            let left = column * columnWidth + fontSize * 2
            let baseline = top - row * rowHeight
            let pronunciationX = { (start: CGFloat) in start + fontSize * CGFloat(word.term.count) * 0.75 }
            switch layout {
            case .numbered:
                draw(String(format: "%04d", index + 1), at: CGPoint(x: left, y: baseline), size: fontSize * 0.8, in: context)
                draw(word.term, at: CGPoint(x: left + fontSize * 4, y: baseline), size: fontSize, bold: true, in: context)
                draw(
                    "[\(word.pronunciation)]",
                    at: CGPoint(x: pronunciationX(left + fontSize * 4), y: baseline),
                    size: fontSize * 0.8,
                    in: context
                )
                draw(word.meaning, at: CGPoint(x: left + fontSize * 4, y: baseline - fontSize * 1.3), size: fontSize * 0.9, in: context)
            case .longMeanings:
                draw(String(format: "%04d", index + 1), at: CGPoint(x: left, y: baseline), size: fontSize * 0.8, in: context)
                draw(word.term, at: CGPoint(x: left + fontSize * 4, y: baseline), size: fontSize, bold: true, in: context)
                draw(word.meaning, at: CGPoint(x: CGFloat(width) * 0.42, y: baseline), size: fontSize * 0.9, in: context)
            case .sideBySide:
                draw(word.term, at: CGPoint(x: left, y: baseline), size: fontSize, bold: true, in: context)
                draw(word.meaning, at: CGPoint(x: left + fontSize * 8, y: baseline), size: fontSize * 0.9, in: context)
            case .stacked:
                draw(word.term, at: CGPoint(x: left, y: baseline), size: fontSize, bold: true, in: context)
                draw(
                    "[\(word.pronunciation)]",
                    at: CGPoint(x: pronunciationX(left), y: baseline),
                    size: fontSize * 0.8,
                    in: context
                )
                draw(word.meaning, at: CGPoint(x: left, y: baseline - fontSize * 1.3), size: fontSize * 0.9, in: context)
            }
        }
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    private func draw(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool = false, in context: CGContext) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "AppleSDGothicNeo-Regular") as CFString, size, nil)
        let string = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        )
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
}
