import CoreData
import Foundation

struct VocabHydrationDiagnosis: Equatable {
    let state: VocabHydrationState
    let message: String?
    let completedMetadataMissingSince: Date?
}

enum VocabHydrationRefreshReason: Equatable, Sendable {
    case initial
    case foreground
    case manual
    case remoteStoreChange
    case successfulImport
    case pollingTick(sceneIsActive: Bool)
}

actor VocabHydrationRefreshQueue {
    private var pendingReason: VocabHydrationRefreshReason?
    private var isDraining = false

    func enqueue(_ reason: VocabHydrationRefreshReason) -> Bool {
        pendingReason = Self.merge(pendingReason, reason)
        guard !isDraining else { return false }
        isDraining = true
        return true
    }

    func dequeue() -> VocabHydrationRefreshReason? {
        guard let pendingReason else {
            isDraining = false
            return nil
        }
        self.pendingReason = nil
        return pendingReason
    }

    private static func merge(
        _ existing: VocabHydrationRefreshReason?,
        _ incoming: VocabHydrationRefreshReason
    ) -> VocabHydrationRefreshReason {
        guard let existing else { return incoming }
        if existing == .successfulImport || incoming == .successfulImport {
            return .successfulImport
        }
        if existing == .manual || incoming == .manual {
            return .manual
        }
        if existing == .initial || incoming == .initial {
            return .initial
        }
        if existing == .remoteStoreChange || incoming == .remoteStoreChange {
            return .remoteStoreChange
        }
        return incoming
    }
}

actor VocabSyncRuntimeStateStore {
    static let shared = VocabSyncRuntimeStateStore()

    private enum Key {
        static let lastDiagnosticAt = "vocabSyncRuntime.lastDiagnosticAt"
        static let lastFullAuditAt = "vocabSyncRuntime.lastFullAuditAt"
        static let fullAuditRequested = "vocabSyncRuntime.fullAuditRequested"
        static let reachedReady = "vocabSyncRuntime.reachedReady"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shouldRunDiagnostic(
        reason: VocabHydrationRefreshReason,
        now: Date = .now
    ) -> Bool {
        VocabHydrationDiagnosticPolicy.diagnosticIsDue(
            reason: reason,
            lastDiagnosticAt: defaults.object(forKey: Key.lastDiagnosticAt) as? Date,
            now: now
        )
    }

    func markDiagnosticCompleted(at date: Date = .now, state: VocabHydrationState) {
        defaults.set(date, forKey: Key.lastDiagnosticAt)
        if state == .ready || state == .localOnly {
            defaults.set(true, forKey: Key.reachedReady)
        }
    }

    func shouldRunFullAudit(now: Date = .now) -> Bool {
        defaults.bool(forKey: Key.fullAuditRequested) || VocabHydrationDiagnosticPolicy.fullAuditIsDue(
            lastAuditAt: defaults.object(forKey: Key.lastFullAuditAt) as? Date,
            now: now
        )
    }

    func requestFullAudit() {
        defaults.set(true, forKey: Key.fullAuditRequested)
    }

    func hasCompletedFullAudit() -> Bool {
        defaults.object(forKey: Key.lastFullAuditAt) as? Date != nil
    }

    func markFullAuditCompleted(at date: Date = .now) {
        defaults.set(date, forKey: Key.lastFullAuditAt)
        defaults.set(false, forKey: Key.fullAuditRequested)
    }

    static func persistedLocalContentIsUsable(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.reachedReady)
    }
}

struct VocabMaintenanceTaskSlot: Equatable {
    private(set) var generation: UUID?

    mutating func begin(generation newGeneration: UUID = UUID()) -> UUID? {
        guard generation == nil else { return nil }
        generation = newGeneration
        return newGeneration
    }

    mutating func cancel() {
        generation = nil
    }

    mutating func complete(generation completedGeneration: UUID) -> Bool {
        guard generation == completedGeneration else { return false }
        generation = nil
        return true
    }
}

enum VocabHydrationDiagnosticPolicy {
    static let foregroundDiagnosticTTL: TimeInterval = 15 * 60
    static let fullAuditTTL: TimeInterval = 7 * 24 * 60 * 60
    static let completedMetadataGracePeriod: TimeInterval = 60
    static let bootstrapPollingDelays: [TimeInterval] = [5, 10, 20, 40, 60]

    static func diagnose(
        localStatus: VocabHydrationStatus,
        claimStatus: VocabBootstrapServerClaimStatus,
        completedMetadataMissingSince: Date?,
        now: Date = .now,
        gracePeriod: TimeInterval = completedMetadataGracePeriod
    ) -> VocabHydrationDiagnosis {
        guard localStatus.state == .awaitingBootstrapMetadata else {
            return VocabHydrationDiagnosis(
                state: localStatus.state,
                message: localStatus.message,
                completedMetadataMissingSince: nil
            )
        }

        switch claimStatus {
        case .missing:
            return VocabHydrationDiagnosis(
                state: .awaitingBootstrapMetadata,
                message: "Mac에서 최초 iCloud 전환을 완료해야 합니다. iPhone은 Mac 단어장을 최초 업로드하지 않습니다.",
                completedMetadataMissingSince: nil
            )
        case .available(let claim) where claim.state == .claimed || claim.state == .seeding:
            return VocabHydrationDiagnosis(
                state: .awaitingBootstrapMetadata,
                message: "Mac이 기존 단어장을 iCloud로 업로드하는 중입니다. Mac 앱을 종료하지 말고 잠시 기다리세요.",
                completedMetadataMissingSince: nil
            )
        case .available(let claim) where claim.state == .completed:
            let startedAt = completedMetadataMissingSince ?? now
            if now.timeIntervalSince(startedAt) >= gracePeriod {
                return VocabHydrationDiagnosis(
                    state: .failed,
                    message: "Mac 업로드 완료는 확인됐지만 최초 동기화 정보를 받지 못했습니다. 네트워크와 iCloud 상태를 확인한 뒤 '동기화 상태 다시 확인'을 실행하세요.",
                    completedMetadataMissingSince: startedAt
                )
            }
            return VocabHydrationDiagnosis(
                state: .awaitingBootstrapMetadata,
                message: "Mac 업로드는 완료됐으며 iPhone이 최초 동기화 정보를 가져오고 있습니다.",
                completedMetadataMissingSince: startedAt
            )
        case .unavailable(let message):
            return VocabHydrationDiagnosis(
                state: .failed,
                message: message,
                completedMetadataMissingSince: completedMetadataMissingSince
            )
        case .available:
            return VocabHydrationDiagnosis(
                state: .failed,
                message: "Mac 최초 동기화 상태를 확인하지 못했습니다.",
                completedMetadataMissingSince: completedMetadataMissingSince
            )
        }
    }

    static func shouldPoll(sceneIsActive: Bool, state: VocabHydrationState) -> Bool {
        sceneIsActive && (state == .awaitingBootstrapMetadata || state == .hydrating)
    }

    static func pollingDelay(attempt: Int) -> TimeInterval? {
        guard bootstrapPollingDelays.indices.contains(attempt) else { return nil }
        return bootstrapPollingDelays[attempt]
    }

    static func shouldRefresh(reason: VocabHydrationRefreshReason, state: VocabHydrationState) -> Bool {
        switch reason {
        case .initial, .manual, .successfulImport:
            true
        case .foreground, .remoteStoreChange:
            false
        case .pollingTick(let sceneIsActive):
            shouldPoll(sceneIsActive: sceneIsActive, state: state)
        }
    }

    static func shouldReconcile(reason: VocabHydrationRefreshReason, state: VocabHydrationState) -> Bool {
        state == .reconciling || (reason == .successfulImport && state == .ready)
    }

    static func diagnosticIsDue(
        reason: VocabHydrationRefreshReason,
        lastDiagnosticAt: Date?,
        now: Date = .now,
        ttl: TimeInterval = foregroundDiagnosticTTL
    ) -> Bool {
        switch reason {
        case .initial, .manual, .successfulImport:
            return true
        case .foreground, .remoteStoreChange:
            return false
        case .pollingTick:
            return true
        }
    }

    static func fullAuditIsDue(
        lastAuditAt: Date?,
        now: Date = .now,
        ttl: TimeInterval = fullAuditTTL
    ) -> Bool {
        guard let lastAuditAt else { return true }
        return now.timeIntervalSince(lastAuditAt) >= ttl
    }

    static func isSuccessfulImportEvent(_ notification: Notification) -> Bool {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else {
            return false
        }
        return event.type == .import && event.endDate != nil && event.succeeded
    }
}
