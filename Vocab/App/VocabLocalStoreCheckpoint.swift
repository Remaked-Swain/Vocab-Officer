import Foundation
import SwiftData

struct VocabLocalStoreCheckpoint: Equatable {
    let directory: URL
    let copiedFiles: [String]
}

struct VocabLocalStoreCheckpointRehearsal: Equatable {
    let wordCount: Int
    let dailySetCount: Int
    let attemptCount: Int
}

struct VocabBootstrapRecoveryManifest: Codable, Equatable {
    let checkpointPath: String
    let canonicalFingerprint: String
    let claimRequest: VocabBootstrapClaimRequest
    let createdAt: Date
}

enum VocabBootstrapRecoveryManifestStore {
    static func save(
        checkpoint: VocabLocalStoreCheckpoint,
        fingerprint: String,
        request: VocabBootstrapClaimRequest,
        fileURL: URL? = nil
    ) throws {
        let destination = try fileURL ?? defaultURL()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let manifest = VocabBootstrapRecoveryManifest(
            checkpointPath: checkpoint.directory.path,
            canonicalFingerprint: fingerprint,
            claimRequest: request,
            createdAt: .now
        )
        try JSONEncoder.vocabSnapshotEncoder.encode(manifest).write(to: destination, options: .atomic)
    }

    static func load(fileURL: URL? = nil) throws -> VocabBootstrapRecoveryManifest? {
        let source = try fileURL ?? defaultURL()
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        return try JSONDecoder.vocabSnapshotDecoder.decode(
            VocabBootstrapRecoveryManifest.self,
            from: Data(contentsOf: source)
        )
    }

    static func defaultURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Vocab", isDirectory: true)
        .appendingPathComponent("BootstrapRecovery", isDirectory: true)
        .appendingPathComponent("manifest.json")
    }
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
    static func createDefaultStoreCheckpoint(now: Date = Date()) throws -> VocabLocalStoreCheckpoint {
        try createCheckpoint(
            storeURL: try VocabModelContainerFactory.storeURL(),
            destinationRoot: try defaultDestinationRoot(),
            now: now
        )
    }

    static func defaultDestinationRoot() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Vocab", isDirectory: true)
        .appendingPathComponent("SyncCheckpoints", isDirectory: true)
    }

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

    @MainActor
    static func rehearseCheckpoint(_ checkpoint: VocabLocalStoreCheckpoint) throws -> VocabLocalStoreCheckpointRehearsal {
        guard let storeFileName = checkpoint.copiedFiles.first(where: { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }) else {
            throw VocabLocalStoreCheckpointError.missingPrimaryStore(checkpoint.directory)
        }
        let storeURL = checkpoint.directory.appendingPathComponent(storeFileName)
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            throw VocabLocalStoreCheckpointError.missingPrimaryStore(storeURL)
        }

        let schema = Schema(VocabModelContainerFactory.schemaModels)
        let configuration = ModelConfiguration(
            "VocabCheckpointRehearsal",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        return VocabLocalStoreCheckpointRehearsal(
            wordCount: try context.fetchCount(FetchDescriptor<WordRecord>()),
            dailySetCount: try context.fetchCount(FetchDescriptor<DailySetRecord>()),
            attemptCount: try context.fetchCount(FetchDescriptor<AttemptRecord>())
        )
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
