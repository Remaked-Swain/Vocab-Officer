import CloudKit
import Foundation
import Observation

/// UI-facing quota state shared by the macOS and iOS roots: the persisted
/// warning, the one-time alert and the user's recheck.
@MainActor
@Observable
final class VocabCloudQuotaStatus {
    /// One instance per process, so the main window and Settings agree.
    static let shared = VocabCloudQuotaStatus()

    private(set) var quotaExceededSince: Date?
    private(set) var isRechecking = false
    var isShowingQuotaAlert = false

    @ObservationIgnored private let store: VocabCloudQuotaStateStore
    @ObservationIgnored private let probe: VocabCloudHealthProbe

    init(store: VocabCloudQuotaStateStore = .shared, probe: VocabCloudHealthProbe = VocabCloudHealthProbe()) {
        self.store = store
        self.probe = probe
        quotaExceededSince = store.quotaExceededSince
    }

    /// Entry point for direct CloudKit requests (claim, snapshot) on any
    /// thread: a full quota reaches the UI state, never the store alone.
    @discardableResult
    nonisolated static func report(
        _ error: Error,
        to status: @escaping @MainActor @Sendable () -> VocabCloudQuotaStatus = { shared }
    ) -> Task<Void, Never>? {
        guard VocabCloudQuotaClassifier.isQuotaExceeded(error) else { return nil }
        return Task { @MainActor in status().noteQuotaExceeded() }
    }

    /// Alerts on this process's first transition to "full"; a warning that
    /// was already persisted at launch does not alert again.
    func noteQuotaExceeded() {
        let wasHealthy = quotaExceededSince == nil
        store.recordQuotaExceeded()
        quotaExceededSince = store.quotaExceededSince
        if wasHealthy { isShowingQuotaAlert = true }
    }

    func noteExportSucceeded() {
        guard quotaExceededSince != nil else { return }
        store.clear()
        quotaExceededSince = nil
    }

    /// A writable probe keeps the warning until the next real export
    /// succeeds; a full quota keeps local use as it is.
    func recheck() async {
        guard quotaExceededSince != nil, !isRechecking else { return }
        isRechecking = true
        defer { isRechecking = false }
        if await probe.check() == .quotaExceeded { noteQuotaExceeded() }
    }
}

/// Recognizes CloudKit's "iCloud storage full" in any error shape the app
/// sees: direct `CKError`s, partial failures and wrapped underlying errors
/// (as `NSPersistentCloudKitContainer` events report them).
enum VocabCloudQuotaClassifier {
    private static let maximumDepth = 4

    static func isQuotaExceeded(_ error: Error) -> Bool {
        isQuotaExceeded(error, depth: 0)
    }

    private static func isQuotaExceeded(_ error: Error, depth: Int) -> Bool {
        guard depth < maximumDepth else { return false }
        if let cloudError = error as? CKError {
            if cloudError.code == .quotaExceeded { return true }
            if let itemErrors = cloudError.partialErrorsByItemID?.values,
               itemErrors.contains(where: { isQuotaExceeded($0, depth: depth + 1) }) {
                return true
            }
        }
        guard let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error else { return false }
        return isQuotaExceeded(underlying, depth: depth + 1)
    }
}

/// What a finished `NSPersistentCloudKitContainer` event means for the
/// quota warning. Takes plain values so it is testable without CloudKit.
enum VocabCloudSyncEventOutcome: Equatable {
    case quotaExceeded
    case exportSucceeded
    case other

    static func classify(isExport: Bool, succeeded: Bool, error: Error?) -> VocabCloudSyncEventOutcome {
        if let error, VocabCloudQuotaClassifier.isQuotaExceeded(error) { return .quotaExceeded }
        return isExport && succeeded && error == nil ? .exportSucceeded : .other
    }
}

enum VocabCloudSyncAvailability: Equatable {
    case available
    case checking
    case quotaExceeded(detectedAt: Date)
    case accountUnavailable
    case temporarilyUnavailable

    static let quotaExceededMessage = "iCloud 저장 공간이 부족해 동기화가 중단되었습니다. 이 기기의 변경 사항은 로컬에 안전하게 저장되지만 다른 기기에는 반영되지 않습니다. iCloud 공간을 확보한 뒤 동기화 상태를 다시 확인하세요."
    static let quotaExceededTitle = "iCloud 동기화 중단 · 로컬에서 사용 중"

    /// A full quota outranks everything else: local use continues and the
    /// warning stays until an export succeeds again.
    static func resolve(
        account: VocabCloudKitAccountState,
        quotaExceededSince: Date?,
        isChecking: Bool
    ) -> VocabCloudSyncAvailability {
        if let quotaExceededSince { return .quotaExceeded(detectedAt: quotaExceededSince) }
        if isChecking { return .checking }
        switch account {
        case .available: return .available
        case .noAccount, .restricted: return .accountUnavailable
        case .unknown, .couldNotDetermine, .temporarilyUnavailable: return .temporarilyUnavailable
        }
    }
}

/// Device-local record of a full quota, so the warning survives relaunch.
/// Never triggers a store replacement: the current store stays the local
/// source of truth while sync is stopped.
struct VocabCloudQuotaStateStore: Sendable {
    static let shared = VocabCloudQuotaStateStore()
    private static let key = "vocabCloudSync.quotaExceededSince"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var quotaExceededSince: Date? {
        defaults.object(forKey: Self.key) as? Date
    }

    /// Keeps the first detection time while the quota stays full.
    func recordQuotaExceeded(at date: Date = .now) {
        guard quotaExceededSince == nil else { return }
        defaults.set(date, forKey: Self.key)
    }

    /// Called only after a real export succeeds, not after a probe.
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

enum VocabCloudHealthProbeResult: Equatable {
    case writable
    case quotaExceeded
    case unavailable
}

/// Writes a tiny fixed private record to tell whether iCloud accepts writes
/// again. A writable result alone does not clear the warning.
struct VocabCloudHealthProbe: Sendable {
    static let recordType = "VocabCloudHealthProbe"
    static let recordName = "VocabCloudHealthProbe-v1"

    private let save: @Sendable (CKRecord) async throws -> Void
    private let delete: @Sendable (CKRecord.ID) async throws -> Void

    /// The container is created per check, never at init, so holders of a
    /// probe (and unsigned test hosts) touch CloudKit only on a recheck.
    init() {
        save = { record in
            let database = CKContainer(identifier: VocabSyncMode.cloudKitContainerIdentifier).privateCloudDatabase
            let (results, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            _ = try results[record.recordID]?.get()
        }
        delete = { recordID in
            let database = CKContainer(identifier: VocabSyncMode.cloudKitContainerIdentifier).privateCloudDatabase
            _ = try await database.deleteRecord(withID: recordID)
        }
    }

    init(
        save: @escaping @Sendable (CKRecord) async throws -> Void,
        delete: @escaping @Sendable (CKRecord.ID) async throws -> Void
    ) {
        self.save = save
        self.delete = delete
    }

    func check(now: Date = .now) async -> VocabCloudHealthProbeResult {
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: Self.recordName))
        record["checkedAt"] = now as CKRecordValue
        do {
            try await save(record)
        } catch {
            return VocabCloudQuotaClassifier.isQuotaExceeded(error) ? .quotaExceeded : .unavailable
        }
        // Best-effort cleanup: a leftover probe is overwritten by the next
        // check (`.allKeys`) and holds no user data.
        try? await delete(record.recordID)
        return .writable
    }
}
