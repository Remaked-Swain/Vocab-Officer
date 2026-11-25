import Foundation
import SwiftData
import Synchronization

enum VocabAuthoringCapability: Sendable {
    case macAuthor
    case readOnlyVocabulary

    static var currentPlatform: VocabAuthoringCapability {
#if os(macOS)
        .macAuthor
#else
        .readOnlyVocabulary
#endif
    }
}

enum VocabMutationAuthority: Equatable, Sendable {
    case allowed
    case integrityBlocked

    static var runtimeCurrent: VocabMutationAuthority {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return .allowed
        }
        return VocabMutationAuthorityRuntime.current
    }
}

enum VocabMutationAuthorityRuntime {
    /// The process's validation epoch and the epoch authorized for mutation.
    private struct Epochs {
        var validation = UUID()
        var authorized: UUID?

        var isAuthorized: Bool { authorized == validation }
    }

    private static let store = VocabMutationLeaseStore()
    /// Read synchronously from mutation checks on any thread, so a `Mutex`
    /// (short, non-suspending critical sections) rather than an actor.
    private static let epochs = Mutex(Epochs())

    static var current: VocabMutationAuthority {
        let epochIsAuthorized = epochs.withLock { $0.isAuthorized }
        return epochIsAuthorized && store.load() != nil ? .allowed : .integrityBlocked
    }

    static func set(_ authority: VocabMutationAuthority) {
        if authority == .integrityBlocked { invalidatePersistedEvidence() }
    }

    static func invalidate() {
        epochs.withLock { $0 = Epochs() }
        store.invalidate()
    }

    static func invalidatePersistedEvidence(receiptURL: URL? = nil) {
        invalidate()
        if let receiptURL {
            VocabFullAuditReceiptStore.invalidate(at: receiptURL)
        } else {
            VocabFullAuditReceiptStore.invalidateDefault()
        }
    }

    @discardableResult
    static func beginValidationEpoch() -> UUID {
        invalidate()
        return currentValidationEpoch
    }

    @discardableResult
    static func beginLaunchValidationEpoch() -> UUID {
        epochs.withLock { state in
            state = Epochs()
            return state.validation
        }
    }

    static func restorePersistedAuthorization(
        container: ModelContainer,
        context: ModelContext,
        receiptURL: URL? = nil
    ) -> Bool {
        do {
            guard let metadata = try VocabMutationLeaseStore.activeMetadata(context: context),
                  metadata.schemaVersion == VocabCloudReconciler.metadataSchemaVersion,
                  !metadata.contentFingerprint.isEmpty,
                  metadata.lastReconciledAt != nil else {
                return false
            }
            let storeIdentity = VocabFullAuditReceipt.storeIdentity(for: container)
            if let lease = store.load(),
               lease.formatVersion == VocabMutationLease.currentFormatVersion,
               VocabFullAuditReceipt.storeIdentity(lease.storeIdentity, matches: storeIdentity),
               lease.bootstrapUUID == metadata.bootstrapUUID,
               lease.schemaVersion == metadata.schemaVersion {
                epochs.withLock { $0.authorized = $0.validation }
                return true
            }
            guard let receipt = try VocabFullAuditReceiptStore.load(
                from: try receiptURL ?? VocabFullAuditReceiptStore.defaultURL()
            ),
                  receipt.formatVersion == VocabFullAuditReceipt.currentFormatVersion,
                  VocabFullAuditReceipt.storeIdentity(receipt.storeIdentity, matches: storeIdentity),
                  receipt.bootstrapUUID == metadata.bootstrapUUID,
                  receipt.schemaVersion == metadata.schemaVersion,
                  receipt.reconciliationVersion == VocabFullAuditReceipt.reconciliationVersion,
                  receipt.importIndexFormatVersion == VocabImportedChangeIndex.currentFormatVersion else {
                return false
            }
            try authorize(
                container: container,
                context: context,
                receipt: receipt,
                validationEpoch: currentValidationEpoch
            )
            return current == .allowed
        } catch {
            return false
        }
    }

    static func noteForegroundReentry() {
        // Foreground reentry is informational; real store-change events still rotate the epoch.
        _ = currentValidationEpoch
    }

    static var currentValidationEpoch: UUID {
        epochs.withLock { $0.validation }
    }

    static func prepareForFullAudit() -> UUID {
        let epoch = epochs.withLock { state in
            state.authorized = nil
            return state.validation
        }
        store.invalidate()
        return epoch
    }

    static func prepareForMaintenanceAudit(
        container: ModelContainer,
        context: ModelContext
    ) -> UUID {
        permitsMutation(container: container, context: context)
            ? currentValidationEpoch
            : prepareForFullAudit()
    }

    static func authorize(
        container: ModelContainer,
        context: ModelContext,
        receipt: VocabFullAuditReceipt,
        validationEpoch expectedEpoch: UUID
    ) throws {
        guard epochs.withLock({ $0.validation == expectedEpoch }) else {
            store.invalidate()
            return
        }
        guard let metadata = try VocabMutationLeaseStore.activeMetadata(context: context) else {
            store.invalidate()
            return
        }
        store.save(VocabMutationLease(
            formatVersion: VocabMutationLease.currentFormatVersion,
            storeIdentity: VocabFullAuditReceipt.storeIdentity(for: container),
            bootstrapUUID: metadata.bootstrapUUID,
            schemaVersion: metadata.schemaVersion,
            metadataFingerprint: metadata.contentFingerprint,
            canonicalFingerprint: receipt.canonicalFingerprint,
            issuedAt: receipt.auditedAt
        ))
        epochs.withLock { state in
            if state.validation == expectedEpoch { state.authorized = expectedEpoch }
        }
    }

    static func permitsMutation(container: ModelContainer, context: ModelContext) -> Bool {
        do {
            guard epochs.withLock({ $0.isAuthorized }) else {
                return false
            }
            guard let lease = store.load(),
                  lease.formatVersion == VocabMutationLease.currentFormatVersion,
                  VocabFullAuditReceipt.storeIdentity(
                    lease.storeIdentity,
                    matches: VocabFullAuditReceipt.storeIdentity(for: container)
                  ),
                  let metadata = try VocabMutationLeaseStore.activeMetadata(context: context),
                  metadata.bootstrapUUID == lease.bootstrapUUID,
                  metadata.schemaVersion == lease.schemaVersion,
                  metadata.schemaVersion == VocabCloudReconciler.metadataSchemaVersion,
                  !metadata.contentFingerprint.isEmpty,
                  metadata.lastReconciledAt != nil else {
                store.invalidate()
                return false
            }
            return true
        } catch {
            store.invalidate()
            return false
        }
    }
}

struct VocabMutationLease: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let storeIdentity: String
    let bootstrapUUID: UUID
    let schemaVersion: Int
    let metadataFingerprint: String
    let canonicalFingerprint: String
    let issuedAt: Date
}

struct VocabMutationLeaseStore {
    private static let key = "vocabSyncRuntime.mutationLease.v1"
    /// Receipt files that could not be deleted on invalidation.
    private static let revokedReceiptsKey = "vocabSyncRuntime.revokedAuditReceipts.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = Self.defaultDefaults()) {
        self.defaults = defaults
    }

    private static func defaultDefaults() -> UserDefaults {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return .standard
        }
        let suiteName = "VocabMutationLeaseTests-\(ProcessInfo.processInfo.processIdentifier)"
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// An unreadable lease is no lease: authority fails closed to the audit
    /// receipt or a fresh audit.
    func load() -> VocabMutationLease? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(VocabMutationLease.self, from: data)
    }

    /// An unsaved lease only costs the next launch a receipt check or audit.
    func save(_ lease: VocabMutationLease) {
        guard let data = try? JSONEncoder().encode(lease) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func invalidate() {
        defaults.removeObject(forKey: Self.key)
    }

    func revokeReceipt(at url: URL) {
        var paths = revokedReceiptPaths()
        paths.insert(Self.receiptPath(url))
        defaults.set(paths.sorted(), forKey: Self.revokedReceiptsKey)
    }

    func isReceiptRevoked(at url: URL) -> Bool {
        revokedReceiptPaths().contains(Self.receiptPath(url))
    }

    func clearReceiptRevocation(at url: URL) {
        var paths = revokedReceiptPaths()
        guard paths.remove(Self.receiptPath(url)) != nil else { return }
        defaults.set(paths.sorted(), forKey: Self.revokedReceiptsKey)
    }

    private func revokedReceiptPaths() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.revokedReceiptsKey) ?? [])
    }

    private static func receiptPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func activeMetadata(context: ModelContext) throws -> CloudBootstrapRecord? {
        var descriptor = FetchDescriptor<CloudBootstrapRecord>(predicate: #Predicate {
            $0.key == "primary" && $0.deletedAt == nil
        })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

enum VocabMutationAuthorityPolicy {
    static func shouldInvalidateForStoreEvent(reason: VocabHydrationRefreshReason) -> Bool {
        switch reason {
        case .successfulImport:
            // CloudKit imports may apply external writes over the local store, so keep this
            // fail-closed until reconciliation refreshes the authority.
            return true
        case .initial, .foreground, .manual, .remoteStoreChange, .pollingTick(_):
            return false
        }
    }

    static func authority(for state: VocabHydrationState) -> VocabMutationAuthority? {
        switch state {
        case .localOnly, .ready:
            .allowed
        case .awaitingBootstrapMetadata, .hydrating, .reconciling:
            .integrityBlocked
        case .failed:
            .integrityBlocked
        }
    }

    static func authority(for error: Error) -> VocabMutationAuthority? {
        error is VocabCloudReconciliationError ? .integrityBlocked : nil
    }
}
