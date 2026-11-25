import Foundation

protocol VocabStableIdentifiedRecord: AnyObject {
    var id: UUID { get }
}

/// Records that soft-delete and scrub their identifying content. Shared by
/// local retirement (`LearningCoordinator`) and tombstone application
/// (`VocabCloudReconciler`, `VocabCloudReconciliationWorker`); not for
/// presentation code.
protocol VocabSoftDeletableRecord: VocabStableIdentifiedRecord {
    var id: UUID { get }
    var updatedAt: Date { get set }
    var deletedAt: Date? { get set }
    @discardableResult func scrubDeletedContent() -> Bool
}

extension VocabSoftDeletableRecord {
    func scrubDeletedContent() -> Bool { false }
}

extension WordRecord: VocabSoftDeletableRecord {
    @discardableResult
    func scrubDeletedContent() -> Bool {
        let changed = !term.isEmpty
            || !normalizedTerm.isEmpty
            || !englishAliases.isEmpty
            || createdAt != .distantPast
            || statusRaw != VocabularyLearningStatus.active.rawValue
        guard changed else { return false }
        term = ""
        normalizedTerm = ""
        englishAliases = []
        createdAt = .distantPast
        statusRaw = VocabularyLearningStatus.active.rawValue
        return changed
    }
}

extension MeaningRecord: VocabSoftDeletableRecord {
    @discardableResult
    func scrubDeletedContent() -> Bool {
        let changed = !text.isEmpty || !normalizedText.isEmpty || !aliases.isEmpty || !successDays.isEmpty
        guard changed else { return false }
        text = ""
        normalizedText = ""
        aliases = []
        successDays = []
        return changed
    }
}

extension DailySetRecord: VocabSoftDeletableRecord {}
extension DailySetItemRecord: VocabSoftDeletableRecord {}
extension AttemptRecord: VocabSoftDeletableRecord {
    @discardableResult
    func scrubDeletedContent() -> Bool {
        let changed = !directionRaw.isEmpty
            || !modeRaw.isEmpty
            || questionIndex != -1
            || !seoulDay.isEmpty
            || !prompt.isEmpty
            || !submittedAnswer.isEmpty
            || !automaticJudgementRaw.isEmpty
            || !finalJudgementRaw.isEmpty
            || correctionRaw != nil
            || !questionFormatRaw.isEmpty
            || matchedMeaningID != nil
            || answeredAt != .distantPast
        guard changed else { return false }
        directionRaw = ""
        modeRaw = ""
        questionIndex = -1
        seoulDay = ""
        prompt = ""
        submittedAnswer = ""
        automaticJudgementRaw = ""
        finalJudgementRaw = ""
        correctionRaw = nil
        questionFormatRaw = ""
        matchedMeaningID = nil
        answeredAt = .distantPast
        return changed
    }
}

extension ReviewStateRecord: VocabSoftDeletableRecord {
    @discardableResult
    func scrubDeletedContent() -> Bool {
        let changed = failureCheck != 0
            || activePriority != 0
            || enToKoStreak != 0
            || koToEnStreak != 0
            || !koToEnSuccessDays.isEmpty
            || latestWrongDirection != nil
            || latestWrongAt != nil
            || lastTestedAt != nil
            || presentationCount != 0
            || lastPresentedAt != nil
        guard changed else { return false }
        failureCheck = 0
        activePriority = 0
        enToKoStreak = 0
        koToEnStreak = 0
        koToEnSuccessDays = []
        latestWrongDirection = nil
        latestWrongAt = nil
        lastTestedAt = nil
        presentationCount = 0
        lastPresentedAt = nil
        return changed
    }
}

extension RecordTombstone: VocabStableIdentifiedRecord {}
extension TestSessionRecord: VocabStableIdentifiedRecord {}
extension AnonymousAggregateRecord: VocabStableIdentifiedRecord {}
extension MemoryAidCacheRecord: VocabSoftDeletableRecord {
    @discardableResult
    func scrubDeletedContent() -> Bool {
        let changed = !modelRaw.isEmpty || !contentSignature.isEmpty || !markdown.isEmpty
        guard changed else { return false }
        modelRaw = ""
        contentSignature = ""
        markdown = ""
        return changed
    }
}
