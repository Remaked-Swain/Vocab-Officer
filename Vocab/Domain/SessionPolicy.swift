import Foundation

public struct MixedSessionCompositionPolicy: Sendable {
    public let questionLimit: Int
    public let referenceSetQuota: Int
    public let activeReviewQuota: Int
    public let masteryMaintenanceQuota: Int
    public let broadRotationTarget: Int

    public init(
        questionLimit: Int = 20,
        referenceSetQuota: Int = 6,
        activeReviewQuota: Int = 4,
        masteryMaintenanceQuota: Int = 2,
        broadRotationTarget: Int = 8
    ) {
        precondition(questionLimit > 0)
        precondition(referenceSetQuota >= 0)
        precondition(activeReviewQuota >= 0)
        precondition(masteryMaintenanceQuota >= 0)
        precondition(broadRotationTarget >= 0)
        precondition(
            referenceSetQuota + activeReviewQuota + masteryMaintenanceQuota + broadRotationTarget
                <= questionLimit
        )
        self.questionLimit = questionLimit
        self.referenceSetQuota = referenceSetQuota
        self.activeReviewQuota = activeReviewQuota
        self.masteryMaintenanceQuota = masteryMaintenanceQuota
        self.broadRotationTarget = broadRotationTarget
    }

    public func select<ID: Hashable & Sendable>(
        reference: [ID],
        referenceCategoryIDs: Set<ID>,
        activeReview: [ID],
        activeReviewCategoryIDs: Set<ID>,
        masteryMaintenance: [ID],
        broadRotation: [ID],
        presentedToday: Set<ID>
    ) -> [ID] {
        let maintenanceIDs = Set(masteryMaintenance)
        let excludedFromBroad = referenceCategoryIDs
            .union(activeReviewCategoryIDs)
            .union(maintenanceIDs)
        let broad = broadRotation.filter { !excludedFromBroad.contains($0) }
        var selected: [ID] = []
        var selectedIDs = Set<ID>()
        var referenceCount = 0
        var reviewCount = 0
        var maintenanceCount = 0

        func append(_ candidates: [ID]) {
            for candidate in candidates where selected.count < questionLimit {
                guard !selectedIDs.contains(candidate) else { continue }
                let isReference = referenceCategoryIDs.contains(candidate)
                let isReview = activeReviewCategoryIDs.contains(candidate)
                let isMaintenance = maintenanceIDs.contains(candidate)
                guard !isReference || referenceCount < referenceSetQuota else { continue }
                guard !isReview || reviewCount < activeReviewQuota else { continue }
                guard !isMaintenance || maintenanceCount < masteryMaintenanceQuota else { continue }
                selectedIDs.insert(candidate)
                selected.append(candidate)
                if isReference { referenceCount += 1 }
                if isReview { reviewCount += 1 }
                if isMaintenance { maintenanceCount += 1 }
            }
        }

        append(masteryMaintenance.filter { !presentedToday.contains($0) })
        append(reference.filter { !presentedToday.contains($0) })
        append(activeReview.filter { !presentedToday.contains($0) })
        append(broad.filter { !presentedToday.contains($0) })

        guard selected.count < questionLimit else { return selected }
        append(masteryMaintenance.filter(presentedToday.contains))
        append(reference.filter(presentedToday.contains))
        append(activeReview.filter(presentedToday.contains))
        append(broad.filter(presentedToday.contains))
        return selected
    }
}

public struct SessionPolicy: Sendable {
    public let maximumCount: Int
    public let mixedComposition: MixedSessionCompositionPolicy
    public let studyCalendar: StudyCalendar

    public init(
        maximumCount: Int = 20,
        mixedComposition: MixedSessionCompositionPolicy = MixedSessionCompositionPolicy(),
        studyCalendar: StudyCalendar = StudyCalendar()
    ) {
        precondition(maximumCount > 0)
        precondition(maximumCount == mixedComposition.questionLimit)
        self.maximumCount = maximumCount
        self.mixedComposition = mixedComposition
        self.studyCalendar = studyCalendar
    }

    public func select(
        from progresses: [WordProgress],
        mode: TestMode,
        on date: Date = Date()
    ) -> [WordProgress] {
        let unique = uniqueProgresses(progresses)
        let today = unique
            .filter { studyCalendar.isSameDay($0.word.createdAt, date) }
            .sorted(by: newestFirst)
        let review = unique
            .filter(eligibleForReview)
            .sorted(by: reviewFirst)

        switch mode {
        case .today:
            return Array(today.prefix(maximumCount))
        case .review:
            return Array(review.prefix(maximumCount))
        case .mixed:
            return mixedSelection(all: unique, today: today, review: review)
        }
    }

    private func mixedSelection(
        all: [WordProgress],
        today: [WordProgress],
        review: [WordProgress]
    ) -> [WordProgress] {
        let progressByID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let todayIDs = today.map(\.id)
        let reviewIDs = review.map(\.id)
        let broadIDs = all.map(\.id)
        return mixedComposition.select(
            reference: todayIDs,
            referenceCategoryIDs: Set(todayIDs),
            activeReview: reviewIDs,
            activeReviewCategoryIDs: Set(reviewIDs),
            masteryMaintenance: [],
            broadRotation: broadIDs,
            presentedToday: []
        ).compactMap { progressByID[$0] }
    }

    private func uniqueProgresses(_ progresses: [WordProgress]) -> [WordProgress] {
        var ids = Set<UUID>()
        return progresses.filter { ids.insert($0.id).inserted }
    }

    private func eligibleForReview(_ progress: WordProgress) -> Bool {
        !progress.reviewState.isMastered && progress.reviewState.activePriority > 0
    }

    private func newestFirst(_ lhs: WordProgress, _ rhs: WordProgress) -> Bool {
        if lhs.word.createdAt != rhs.word.createdAt {
            return lhs.word.createdAt > rhs.word.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func reviewFirst(_ lhs: WordProgress, _ rhs: WordProgress) -> Bool {
        if lhs.reviewState.activePriority != rhs.reviewState.activePriority {
            return lhs.reviewState.activePriority > rhs.reviewState.activePriority
        }
        if lhs.reviewState.failureCheck != rhs.reviewState.failureCheck {
            return lhs.reviewState.failureCheck > rhs.reviewState.failureCheck
        }
        let lhsDate = lhs.reviewState.lastAttemptAt ?? lhs.word.createdAt
        let rhsDate = rhs.reviewState.lastAttemptAt ?? rhs.word.createdAt
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
