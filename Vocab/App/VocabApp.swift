import Foundation
import SwiftData
import SwiftUI

@main
struct VocabApp: App {
    private let container: ModelContainer = Self.makeContainer()

    private static func makeContainer() -> ModelContainer {
        do {
            let configuration = ModelConfiguration(url: try storeURL())
            return try ModelContainer(
                for:
                WordRecord.self,
                MeaningRecord.self,
                DailySetRecord.self,
                DailySetItemRecord.self,
                TestSessionRecord.self,
                AttemptRecord.self,
                ReviewStateRecord.self,
                AnonymousAggregateRecord.self,
                configurations: configuration
            )
        } catch {
            fatalError("Unable to prepare local learning data: \(error.localizedDescription)")
        }
    }

    private static func storeURL() throws -> URL {
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

    var body: some Scene {
        WindowGroup("Vocab", id: "main") {
            RootView()
                .modelContainer(container)
        }
        .defaultSize(width: 1160, height: 760)
        .windowResizability(.automatic)

        Settings {
            SettingsView()
                .modelContainer(container)
        }
    }
}
