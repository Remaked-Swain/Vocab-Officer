import Foundation

public struct SessionPolicy: Sendable {
    public let maximumCount: Int
    public let mixedTodayCount: Int
    public let studyCalendar: StudyCalendar

    public init(
        maximumCount: Int = 20,
        mixedTodayCount: Int = 10,
        studyCalendar: StudyCalendar = StudyCalendar()
    ) {
        precondition(maximumCount > 0)
        precondition(mixedTodayCount >= 0 && mixedTodayCount <= maximumCount)
        self.maximumCount = maximumCount
        self.mixedTodayCount = mixedTodayCount
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
            return mixedSelection(today: today, review: review)
        }
    }

    private func mixedSelection(
        today: [WordProgress],
        review: [WordProgress]
    ) -> [WordProgress] {
        let reviewCount = maximumCount - mixedTodayCount
        var selected: [WordProgress] = []
        var selectedIDs = Set<UUID>()

        append(Array(review.prefix(reviewCount)), to: &selected, ids: &selectedIDs)
        let uniqueToday = today.filter { !selectedIDs.contains($0.id) }
        append(Array(uniqueToday.prefix(mixedTodayCount)), to: &selected, ids: &selectedIDs)

        let unselectedReview = review.filter { !selectedIDs.contains($0.id) }
        append(unselectedReview, to: &selected, ids: &selectedIDs)
        let unselectedToday = today.filter { !selectedIDs.contains($0.id) }
        append(unselectedToday, to: &selected, ids: &selectedIDs)

        return Array(selected.prefix(maximumCount))
    }

    private func append(
        _ candidates: [WordProgress],
        to selected: inout [WordProgress],
        ids selectedIDs: inout Set<UUID>
    ) {
        for candidate in candidates where selected.count < maximumCount {
            if selectedIDs.insert(candidate.id).inserted {
                selected.append(candidate)
            }
        }
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
