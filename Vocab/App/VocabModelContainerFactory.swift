import Foundation
import SwiftData

enum VocabSyncMode: String, CaseIterable, Identifiable {
    case localOnly
    case cloudKitPrivate

    static let userDefaultsKey = "vocabSyncMode"
    static let cloudKitContainerIdentifier = "iCloud.com.swainyun.Vocab"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localOnly:
            "이 Mac에만 저장"
        case .cloudKitPrivate:
            "iCloud 동기화"
        }
    }

    var detail: String {
        switch self {
        case .localOnly:
            "현재 macOS 앱의 기존 저장 방식을 유지합니다."
        case .cloudKitPrivate:
            "같은 Apple ID의 개인 iCloud 저장소로 단어장을 동기화합니다."
        }
    }

    static func current(defaults: UserDefaults = .standard, allowsCloudKit: Bool = false) -> VocabSyncMode {
        guard
            let rawValue = defaults.string(forKey: userDefaultsKey),
            let mode = VocabSyncMode(rawValue: rawValue)
        else {
            return .localOnly
        }
        guard allowsCloudKit || mode == .localOnly else {
            return .localOnly
        }
        return mode
    }
}

enum VocabModelContainerFactory {
    static let schemaModels: [any PersistentModel.Type] = [
        WordRecord.self,
        MeaningRecord.self,
        DailySetRecord.self,
        DailySetItemRecord.self,
        TestSessionRecord.self,
        AttemptRecord.self,
        ReviewStateRecord.self,
        AnonymousAggregateRecord.self,
        MemoryAidCacheRecord.self
    ]

    static func makeContainer(syncMode: VocabSyncMode = .current()) throws -> ModelContainer {
        let configuration = try makeConfiguration(syncMode: syncMode)
        return try ModelContainer(for: Schema(schemaModels), configurations: configuration)
    }

    static func makeConfiguration(syncMode: VocabSyncMode) throws -> ModelConfiguration {
        switch syncMode {
        case .localOnly:
            return ModelConfiguration(
                "VocabLocal",
                schema: Schema(schemaModels),
                url: try storeURL(),
                cloudKitDatabase: .none
            )
        case .cloudKitPrivate:
            return ModelConfiguration(
                "VocabCloud",
                schema: Schema(schemaModels),
                url: try storeURL(),
                cloudKitDatabase: .private(VocabSyncMode.cloudKitContainerIdentifier)
            )
        }
    }

    static func storeURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("Vocab", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let destination = directory.appendingPathComponent("Vocab.store")
        try migrateLegacyStoreIfNeeded(to: destination, fileManager: fileManager, appSupport: appSupport)
        return destination
    }

    private static func migrateLegacyStoreIfNeeded(to destination: URL, fileManager: FileManager, appSupport: URL) throws {
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        let legacy = appSupport.appendingPathComponent("default.store")
        guard fileManager.fileExists(atPath: legacy.path) else { return }

        try moveStoreFileIfNeeded(from: legacy, to: destination, fileManager: fileManager)
        try moveStoreFileIfNeeded(
            from: appSupport.appendingPathComponent("default.store-shm"),
            to: directorySibling(of: destination, name: "Vocab.store-shm"),
            fileManager: fileManager
        )
        try moveStoreFileIfNeeded(
            from: appSupport.appendingPathComponent("default.store-wal"),
            to: directorySibling(of: destination, name: "Vocab.store-wal"),
            fileManager: fileManager
        )
    }

    private static func moveStoreFileIfNeeded(from source: URL, to destination: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    private static func directorySibling(of url: URL, name: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(name)
    }
}
