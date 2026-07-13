import Foundation

struct VocabLocalStoreCheckpoint: Equatable {
    let directory: URL
    let copiedFiles: [String]
}

enum VocabLocalStoreCheckpointError: LocalizedError, Equatable {
    case missingPrimaryStore(URL)

    var errorDescription: String? {
        switch self {
        case .missingPrimaryStore:
            "기존 단어장 저장소 파일을 찾지 못해 iCloud 전환 전 체크포인트를 만들 수 없습니다."
        }
    }
}

enum VocabLocalStoreCheckpointStore {
    static func createCheckpoint(
        storeURL: URL,
        destinationRoot: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> VocabLocalStoreCheckpoint {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw VocabLocalStoreCheckpointError.missingPrimaryStore(storeURL)
        }

        if !fileManager.fileExists(atPath: destinationRoot.path) {
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        }

        let checkpointDirectory = destinationRoot.appendingPathComponent(
            "VocabStoreCheckpoint-\(timestamp(for: now))",
            isDirectory: true
        )
        try fileManager.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true)

        var copiedFiles: [String] = []
        for source in storeCompanionURLs(for: storeURL) where fileManager.fileExists(atPath: source.path) {
            let destination = checkpointDirectory.appendingPathComponent(source.lastPathComponent)
            try fileManager.copyItem(at: source, to: destination)
            copiedFiles.append(source.lastPathComponent)
        }

        try writeManifest(
            to: checkpointDirectory,
            originalStoreURL: storeURL,
            copiedFiles: copiedFiles,
            createdAt: now,
            fileManager: fileManager
        )

        return VocabLocalStoreCheckpoint(directory: checkpointDirectory, copiedFiles: copiedFiles)
    }

    static func storeCompanionURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            sibling(of: storeURL, suffix: "-wal"),
            sibling(of: storeURL, suffix: "-shm")
        ]
    }

    private static func sibling(of storeURL: URL, suffix: String) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(storeURL.lastPathComponent + suffix)
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func writeManifest(
        to directory: URL,
        originalStoreURL: URL,
        copiedFiles: [String],
        createdAt: Date,
        fileManager: FileManager
    ) throws {
        let manifest = StoreCheckpointManifest(
            originalStorePath: originalStoreURL.path,
            copiedFiles: copiedFiles,
            createdAt: createdAt
        )
        let data = try JSONEncoder.storeCheckpointEncoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }
}

private struct StoreCheckpointManifest: Encodable {
    let originalStorePath: String
    let copiedFiles: [String]
    let createdAt: Date
}

private extension JSONEncoder {
    static var storeCheckpointEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
