import Foundation
import ImageIO
import Vision

enum OCRTextRecognizer {
    static func recognizeTokens(from url: URL) throws -> [OCRTextToken] {
        guard let cgImage = downsampledCGImage(from: url) else {
            throw OCRError.unreadableImage
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return nil
            }
            return OCRTextToken(text: text, boundingBox: observation.boundingBox)
        }
    }

    private static func downsampledCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_400
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

enum OCRError: LocalizedError {
    case unreadableImage
    case noText

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "이미지를 읽을 수 없습니다."
        case .noText:
            "이미지에서 텍스트를 찾지 못했습니다."
        }
    }
}
