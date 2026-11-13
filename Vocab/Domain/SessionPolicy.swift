import Foundation

public struct MixedSessionCompositionPolicy: Sendable {
    public let questionLimit: Int
    public let promotionDueQuota: Int
    public let activeReviewQuota: Int
    public let masteryMaintenanceQuota: Int
    public let broadRotationTarget: Int

    public init(
        questionLimit: Int = 20,
        promotionDueQuota: Int = 6,
        activeReviewQuota: Int = 4,
        masteryMaintenanceQuota: Int = 2,
        broadRotationTarget: Int = 8
    ) {
        precondition(questionLimit > 0)
        precondition(promotionDueQuota >= 0)
        precondition(activeReviewQuota >= 0)
        precondition(masteryMaintenanceQuota >= 0)
        precondition(broadRotationTarget >= 0)
        precondition(
            promotionDueQuota + activeReviewQuota + masteryMaintenanceQuota + broadRotationTarget
                <= questionLimit
        )
        self.questionLimit = questionLimit
        self.promotionDueQuota = promotionDueQuota
        self.activeReviewQuota = activeReviewQuota
        self.masteryMaintenanceQuota = masteryMaintenanceQuota
        self.broadRotationTarget = broadRotationTarget
    }

    public func select<ID: Hashable & Sendable>(
        promotionDue: [ID],
        promotionDueCategoryIDs: Set<ID>,
        activeReview: [ID],
        activeReviewCategoryIDs: Set<ID>,
        masteryMaintenance: [ID],
        broadRotation: [ID],
        presentedToday: Set<ID>
    ) -> [ID] {
        let maintenanceIDs = Set(masteryMaintenance)
        let excludedFromBroad = promotionDueCategoryIDs
            .union(activeReviewCategoryIDs)
            .union(maintenanceIDs)
        let broad = broadRotation.filter { !excludedFromBroad.contains($0) }
        var selected: [ID] = []
        var selectedIDs = Set<ID>()
        var promotionCount = 0
        var reviewCount = 0
        var maintenanceCount = 0

        func append(_ candidates: [ID]) {
            for candidate in candidates where selected.count < questionLimit {
                guard !selectedIDs.contains(candidate) else { continue }
                let isPromotionDue = promotionDueCategoryIDs.contains(candidate)
                let isReview = activeReviewCategoryIDs.contains(candidate)
                let isMaintenance = maintenanceIDs.contains(candidate)
                guard !isPromotionDue || promotionCount < promotionDueQuota else { continue }
                guard !isReview || reviewCount < activeReviewQuota else { continue }
                guard !isMaintenance || maintenanceCount < masteryMaintenanceQuota else { continue }
                selectedIDs.insert(candidate)
                selected.append(candidate)
                if isPromotionDue { promotionCount += 1 }
                if isReview { reviewCount += 1 }
                if isMaintenance { maintenanceCount += 1 }
            }
        }

        append(masteryMaintenance.filter { !presentedToday.contains($0) })
        append(promotionDue.filter { !presentedToday.contains($0) })
        append(activeReview.filter { !presentedToday.contains($0) })
        append(broad.filter { !presentedToday.contains($0) })

        guard selected.count < questionLimit else { return selected }
        append(masteryMaintenance.filter(presentedToday.contains))
        append(promotionDue.filter(presentedToday.contains))
        append(activeReview.filter(presentedToday.contains))
        append(broad.filter(presentedToday.contains))
        return selected
    }
}
