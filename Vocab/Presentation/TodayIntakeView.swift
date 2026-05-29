import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct TodayIntakeView: View {
    private enum IntakeMode: String, CaseIterable, Identifiable {
        case paste = "붙여넣기"
        case image = "이미지 OCR"
        case manual = "직접 입력"

        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var context
    @State private var mode: IntakeMode = .paste
    @State private var pastedText = ""
    @State private var drafts = (0..<100).map { _ in WordDraft() }
    @State private var message: String?
    @State private var isError = false
    @State private var isImportingImage = false
    @State private var isRecognizingText = false

    private var filledCount: Int {
        drafts.filter { !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var pastedDrafts: [WordDraft] {
        (try? DailyIntakePasteParser.parse(pastedText)) ?? []
    }

    private var pasteStatus: (String, Bool) {
        guard !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("100개 단어를 한 번에 붙여넣으세요.", false)
        }
        do {
            let count = try DailyIntakePasteParser.parse(pastedText).count
            return (count == 100 ? "100개가 확인되었습니다. 바로 저장할 수 있습니다." : "\(count)개가 인식되었습니다. 정확히 100개가 필요합니다.", count == 100)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading) {
                    Text("오늘 입력")
                        .font(.largeTitle.weight(.semibold))
                    Text("오늘 학습할 100개 항목을 등록하세요. 기존 표제어는 같은 단어에 새 뜻만 누적됩니다.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.body.weight(.medium))
                    .foregroundStyle(isError ? .red : .green)
            }

            Picker("입력 방법", selection: $mode) {
                ForEach(IntakeMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .frame(maxWidth: 430)

            switch mode {
            case .paste:
                pasteEntry
            case .image:
                imageEntry
            case .manual:
                manualEntry
            }
        }
        .padding(28)
        .toolbar {
            ToolbarItem {
                Button("입력 내용 비우기") {
                    pastedText = ""
                    drafts = (0..<100).map { _ in WordDraft() }
                    message = nil
                }
                .controlSize(.large)
            }
        }
    }

    private var imageEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("단어장 캡쳐본에서 텍스트 추출") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("이미지를 여러 장 선택하면 macOS Vision OCR로 로컬에서 추출한 뒤 앱 입력 형식으로 정리합니다. 저장 전 반드시 100개 인식 결과를 직접 검수하세요.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(isRecognizingText ? "텍스트 추출 중..." : "이미지 선택") {
                            isImportingImage = true
                        }
                        .controlSize(.large)
                        .disabled(isRecognizingText)
                        if isRecognizingText {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    TextEditor(text: $pastedText)
                        .font(.system(.title3, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 320)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.quaternary, lineWidth: 1)
                        }
                        .accessibilityLabel("OCR 추출 결과 검수 입력창")
                    Label(pasteStatus.0, systemImage: pasteStatus.1 ? "checkmark.circle.fill" : "info.circle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(pasteStatus.1 ? .green : .secondary)
                }
                .padding(10)
            }

            HStack {
                Text("\(pastedDrafts.count) / 100")
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .accessibilityLabel("인식된 신규 단어 \(pastedDrafts.count)개")
                Spacer()
                Button("검수한 100개 저장") {
                    save(pastedDrafts)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!pasteStatus.1)
            }
        }
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            handleImageImport(result)
        }
    }

    private var pasteEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("100개 일괄 붙여넣기") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("형식: 0001-well-known-널리 알려진 또는 sample<TAB>표본, 예시")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $pastedText)
                        .font(.system(.title3, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 320)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.quaternary, lineWidth: 1)
                        }
                        .accessibilityLabel("단어 100개 붙여넣기 입력창")
                    Label(pasteStatus.0, systemImage: pasteStatus.1 ? "checkmark.circle.fill" : "info.circle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(pasteStatus.1 ? .green : .secondary)
                }
                .padding(10)
            }

            HStack {
                Text("\(pastedDrafts.count) / 100")
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .accessibilityLabel("인식된 신규 단어 \(pastedDrafts.count)개")
                Spacer()
                Button("붙여넣은 100개 저장") {
                    save(pastedDrafts)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!pasteStatus.1)
            }
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("필요한 경우 개별 행을 수정하여 입력할 수 있습니다.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(filledCount) / 100")
                    .font(.title2.monospacedDigit().weight(.semibold))
            }
            Table($drafts) {
                TableColumn("#") { draft in
                    if let index = drafts.firstIndex(where: { $0.id == draft.wrappedValue.id }) {
                        Text("\(index + 1)")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .width(48)
                TableColumn("English") { $draft in
                    TextField("headword", text: $draft.term)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .controlSize(.large)
                }
                .width(min: 220)
                TableColumn("한국어 뜻 (쉼표로 구분)") { $draft in
                    TextField("뜻1, 뜻2", text: $draft.meanings)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .controlSize(.large)
                }
            }
            .accessibilityLabel("오늘 신규 단어 직접 입력 표")

            HStack {
                Spacer()
                Button("직접 입력한 100개 저장") {
                    save(drafts)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(filledCount != 100)
            }
        }
    }

    private func save(_ values: [WordDraft]) {
        do {
            try LearningCoordinator(context: context).saveDailySet(values)
            message = "Asia/Seoul 기준 오늘의 신규 100단어 세트를 저장했습니다."
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            isRecognizingText = true
            Task {
                do {
                    let text = try await recognizeText(from: urls)
                    await MainActor.run {
                        pastedText = text
                        message = "\(urls.count)장 이미지에서 OCR 텍스트를 추출했습니다. 저장 전 원본 캡쳐본과 대조하세요."
                        isError = false
                        isRecognizingText = false
                    }
                } catch {
                    await MainActor.run {
                        message = error.localizedDescription
                        isError = true
                        isRecognizingText = false
                    }
                }
            }
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func recognizeText(from urls: [URL]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var pages: [[OCRTextToken]] = []
            for url in urls {
                try autoreleasepool {
                    let imageTokens = try recognizeTokens(from: url)
                    pages.append(imageTokens)
                }
            }
            guard !pages.allSatisfy(\.isEmpty) else { throw OCRError.noText }
            return try OCRVocabularyFormatter.formatPages(pages)
        }.value
    }
}

private func recognizeTokens(from url: URL) throws -> [OCRTextToken] {
    guard let cgImage = downsampledCGImage(from: url) else {
        throw OCRError.unreadableImage
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["ko-KR", "en-US"]
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: cgImage)
    try handler.perform([request])
    return (request.results ?? [])
        .compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return nil
            }
            return OCRTextToken(text: text, boundingBox: observation.boundingBox)
        }
}

private func downsampledCGImage(from url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: false,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 2_400
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

private enum OCRError: LocalizedError {
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
