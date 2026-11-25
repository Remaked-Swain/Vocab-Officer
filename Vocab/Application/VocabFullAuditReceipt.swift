import CryptoKit
import Foundation
import SwiftData

struct VocabFullAuditReceipt: Codable, Equatable {
    static let currentFormatVersion = 1
    static let reconciliationVersion = 2

    var formatVersion: Int
    var storeIdentity: String
    var bootstrapUUID: UUID
    var schemaVersion: Int
    var reconciliationVersion: Int
    var importIndexFormatVersion: Int
    var canonicalFingerprint: String
    var expectedCounts: VocabEntityCounts? = nil
    var requiredIDDigest: String? = nil
    var auditedAt: Date

    func validates(container: ModelContainer, snapshot: VocabSyncSnapshot) throws -> Bool {
        let currentFingerprint = try snapshot.contentFingerprint()
        return formatVersion == Self.currentFormatVersion
            && Self.storeIdentity(storeIdentity, matches: Self.storeIdentity(for: container))
            && bootstrapUUID == snapshot.syncMetadata?.bootstrapUUID
            && schemaVersion == VocabCloudReconciler.metadataSchemaVersion
            && reconciliationVersion == Self.reconciliationVersion
            && importIndexFormatVersion == VocabImportedChangeIndex.currentFormatVersion
            && canonicalFingerprint == currentFingerprint
    }

    static func storeIdentity(for container: ModelContainer) -> String {
        canonicalStoreIdentity(
            container.configurations.map { $0.url.path }.joined(separator: "|")
        )
    }

    static func storeIdentity(_ lhs: String, matches rhs: String) -> Bool {
        canonicalStoreIdentity(lhs) == canonicalStoreIdentity(rhs)
    }

    private static func canonicalStoreIdentity(_ identity: String) -> String {
        identity.split(separator: "|", omittingEmptySubsequences: false)
            .map {
                let standardizedPath = URL(fileURLWithPath: String($0))
                    .standardizedFileURL
                    .path
                let aliasedPath: String
                if standardizedPath == "/var" || standardizedPath.hasPrefix("/var/") {
                    aliasedPath = "/private" + standardizedPath
                } else if standardizedPath == "/tmp" || standardizedPath.hasPrefix("/tmp/") {
                    aliasedPath = "/private" + standardizedPath
                } else {
                    aliasedPath = standardizedPath
                }
                let resolvedPath = URL(fileURLWithPath: aliasedPath).resolvingSymlinksInPath().path
                return stableApplicationContainerPath(resolvedPath)
            }
            .sorted()
            .joined(separator: "|")
    }

    private static func stableApplicationContainerPath(_ path: String) -> String {
        let marker = "/Containers/Data/Application/"
        guard let markerRange = path.range(of: marker) else { return path }
        let suffix = path[markerRange.upperBound...]
        guard let separator = suffix.firstIndex(of: "/"),
              UUID(uuidString: String(suffix[..<separator])) != nil else { return path }
        return String(path[..<markerRange.upperBound]) + "<container>" + suffix[separator...]
    }
}

enum VocabRequiredIDDigest {
    static func make(snapshot: VocabSyncSnapshot) -> String {
        var ids = snapshot.words.map { "w:\($0.id.uuidString)" }
        ids.append(contentsOf: snapshot.words.flatMap { word in word.meanings.map { "m:\($0.id.uuidString)" } })
        ids.append(contentsOf: snapshot.dailySets.map { "s:\($0.id.uuidString)" })
        ids.append(contentsOf: snapshot.dailySets.flatMap { set in set.items.map { "i:\($0.id.uuidString)" } })
        ids.append(contentsOf: snapshot.testSessions.map { "t:\($0.id.uuidString)" })
        ids.append(contentsOf: snapshot.attempts.map { "a:\($0.id.uuidString)" })
        ids.append(contentsOf: snapshot.tombstones.map { "d:\($0.id.uuidString)" })
        return SHA256.hash(data: Data(ids.sorted().joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func counts(snapshot: VocabSyncSnapshot) -> VocabEntityCounts {
        VocabEntityCounts(
            words: snapshot.words.count,
            meanings: snapshot.words.reduce(0) { $0 + $1.meanings.count },
            dailySets: snapshot.dailySets.count,
            dailySetItems: snapshot.dailySets.reduce(0) { $0 + $1.items.count },
            testSessions: snapshot.testSessions.count,
            attempts: snapshot.attempts.count,
            anonymousAggregates: snapshot.anonymousAggregates.count,
            memoryAidCaches: snapshot.memoryAidCaches.count,
            tombstones: snapshot.tombstones.count
        )
    }
}

enum VocabFullAuditReceiptStore {
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Vocab/SyncRuntime", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("full-audit-receipt-v1.json")
    }

    /// Revocations live in the lease store's defaults, which cannot fail to
    /// write, so a receipt file that survives invalidation stays unusable.
    private static let revocations = VocabMutationLeaseStore()

    static func load(from url: URL) throws -> VocabFullAuditReceipt? {
        guard FileManager.default.fileExists(atPath: url.path),
              !revocations.isReceiptRevoked(at: url) else { return nil }
        return try JSONDecoder.vocabSnapshotDecoder.decode(
            VocabFullAuditReceipt.self,
            from: Data(contentsOf: url)
        )
    }

    static func save(_ receipt: VocabFullAuditReceipt, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.vocabSnapshotEncoder.encode(receipt).write(to: url, options: .atomic)
        revocations.clearReceiptRevocation(at: url)
    }

    static func invalidateDefault() {
        // Without Application Support no receipt can be loaded either:
        // restoration resolves the same URL and fails closed.
        guard let url = try? defaultURL() else { return }
        invalidate(at: url)
    }

    /// A receipt alone reauthorizes mutations at cold launch, so one that
    /// cannot be deleted is revoked instead of silently left valid.
    static func invalidate(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            revocations.revokeReceipt(at: url)
        }
    }
}
