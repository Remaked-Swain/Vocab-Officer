import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct BackupSettingsSection: View {
    @Environment(\.modelContext) private var context
    @State private var document: JSONDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var notice: String?

    var body: some View {
        Section("데이터 백업") {
            Button("JSON 내보내기") {
                let container = context.container
                Task {
                    do {
                        let data = try await BackupService(modelContainer: container).externalExportData()
                        document = JSONDocument(data: data)
                        exporting = true
                    } catch {
                        notice = error.localizedDescription
                    }
                }
            }
            Button("JSON 전체 교체 복원") {
                importing = true
            }
            Text("복원 전 현재 데이터의 관리 백업을 자동 생성합니다. 외부 백업에서 삭제된 단어가 다시 유입될 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let notice {
                Text(notice).font(.caption)
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Vocab-backup") { result in
            if case .failure(let error) = result { notice = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            let container = context.container
            Task {
                do {
                    let url = try result.get()
                    guard url.startAccessingSecurityScopedResource() else { throw BackupError.unsupportedSchema }
                    defer { url.stopAccessingSecurityScopedResource() }
                    let data = try await Task.detached { try Data(contentsOf: url) }.value
                    try await BackupService(modelContainer: container).restore(from: data)
                    notice = "백업을 복원했습니다."
                } catch {
                    notice = error.localizedDescription
                }
            }
        }
    }
}
