import Foundation
import SwiftData

enum VocabSyncMode: String, CaseIterable, Identifiable, Sendable {
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

    static func current(
        defaults: UserDefaults = .standard,
        allowsCloudKit: Bool = false,
        defaultMode: VocabSyncMode = .localOnly
    ) -> VocabSyncMode {
        guard
            let rawValue = defaults.string(forKey: userDefaultsKey),
            let mode = VocabSyncMode(rawValue: rawValue)
        else {
            return defaultMode
        }
        guard allowsCloudKit || mode == .localOnly else {
            return .localOnly
        }
        return mode
    }
}

struct VocabLaunchPlan {
    let container: ModelContainer
    let mode: VocabSyncMode
    let connectionError: String?

    var isUsable: Bool { connectionError == nil }
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
        MemoryAidCacheRecord.self,
        CloudBootstrapRecord.self,
        BootstrapExportReceipt.self,
        RecordTombstone.self
    ]

    static func makeContainer(syncMode: VocabSyncMode = .current()) throws -> ModelContainer {
        try makeContainer(syncMode: syncMode, storeURL: nil)
    }

    static func makeContainer(syncMode: VocabSyncMode, storeURL: URL) throws -> ModelContainer {
        try makeContainer(syncMode: syncMode, storeURL: Optional(storeURL))
    }

    private static func makeContainer(syncMode: VocabSyncMode, storeURL: URL?) throws -> ModelContainer {
        let configuration = try makeConfiguration(syncMode: syncMode, storeURL: storeURL)
        return try ModelContainer(
            for: Schema(VocabSchemaV3.models),
            migrationPlan: VocabSchemaMigrationPlan.self,
            configurations: configuration
        )
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(schemaModels)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    static func makeLaunchPlan(
        preferredMode: VocabSyncMode,
        open: (VocabSyncMode) throws -> ModelContainer = makeContainer(syncMode:)
    ) -> VocabLaunchPlan {
        do {
            return VocabLaunchPlan(container: try open(preferredMode), mode: preferredMode, connectionError: nil)
        } catch {
            let errorContainer: ModelContainer
            do {
                let schema = Schema(schemaModels)
                let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                errorContainer = try ModelContainer(for: schema, configurations: configuration)
            } catch {
                fatalError("Unable to prepare recovery UI data: \(error.localizedDescription)")
            }
            let target = preferredMode == .cloudKitPrivate ? "iCloud mirrored 저장소" : "로컬 저장소"
            return VocabLaunchPlan(
                container: errorContainer,
                mode: preferredMode,
                connectionError: "\(target)를 열지 못했습니다. 기존 저장소와 체크포인트는 변경하거나 삭제하지 않았습니다. \(error.localizedDescription)"
            )
        }
    }

    static func makeConfiguration(syncMode: VocabSyncMode) throws -> ModelConfiguration {
        try makeConfiguration(syncMode: syncMode, storeURL: nil)
    }

    private static func makeConfiguration(syncMode: VocabSyncMode, storeURL: URL?) throws -> ModelConfiguration {
        switch syncMode {
        case .localOnly:
            return ModelConfiguration(
                "VocabLocal",
                schema: Schema(schemaModels),
                url: try storeURL ?? localStoreURL(),
                cloudKitDatabase: .none
            )
        case .cloudKitPrivate:
            return ModelConfiguration(
                "VocabCloud",
                schema: Schema(schemaModels),
                url: try storeURL ?? mirroredStoreURL(),
                cloudKitDatabase: .private(VocabSyncMode.cloudKitContainerIdentifier)
            )
        }
    }

    static func localStoreURL() throws -> URL {
        return try storeURL(named: "Vocab.store", migrateLegacyDefaultStore: true)
    }

    static func localStoreURL(applicationSupportURL: URL) throws -> URL {
        try storeURL(
            named: "Vocab.store",
            migrateLegacyDefaultStore: true,
            applicationSupportURL: applicationSupportURL
        )
    }

    static func mirroredStoreURL() throws -> URL {
        try storeURL(named: "VocabMirrored.store", migrateLegacyDefaultStore: false)
    }

    static func storeURL() throws -> URL {
        try localStoreURL()
    }

    private static func storeURL(
        named storeName: String,
        migrateLegacyDefaultStore: Bool,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try applicationSupportURL ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("Vocab", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let destination = directory.appendingPathComponent(storeName)
        if migrateLegacyDefaultStore {
            try migrateLegacyStoreIfNeeded(to: destination, fileManager: fileManager, appSupport: appSupport)
        }
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
