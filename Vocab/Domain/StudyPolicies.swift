import Foundation

public struct AnswerJudge: Sendable {
    public init() {}

    public func evaluate(
        answer: String,
        for word: Word,
        direction: Direction
    ) -> AnswerEvaluation {
        let entered = Self.normalized(answer)
        let expected = acceptedAnswers(for: word, direction: direction)

        guard !entered.isEmpty else {
            return AnswerEvaluation(judgement: .incorrect)
        }

        if let match = expected.first(where: { Self.normalized($0.answer) == entered }) {
            return AnswerEvaluation(
                judgement: .correct,
                matchedAnswer: match.answer,
                matchedMeaningID: match.meaningID
            )
        }

        let suggestion = expected
            .map { ($0.answer, Self.editDistance(entered, Self.normalized($0.answer))) }
            .filter { $0.1 <= suggestionDistance(for: Self.normalized($0.0)) }
            .sorted {
                if $0.1 != $1.1 {
                    return $0.1 < $1.1
                }
                return $0.0 < $1.0
            }
            .first?
            .0

        if let suggestion {
            return AnswerEvaluation(judgement: .unknown, suggestion: suggestion)
        }

        return AnswerEvaluation(judgement: .incorrect)
    }

    public func judge(
        answer: String,
        for word: Word,
        direction: Direction
    ) -> Judgement {
        evaluate(answer: answer, for: word, direction: direction).judgement
    }

    public static func normalized(_ value: String) -> String {
        let trimmedPunctuation = value.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters)
        )
        let collapsedWhitespace = trimmedPunctuation
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        return collapsedWhitespace
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private func acceptedAnswers(
        for word: Word,
        direction: Direction
    ) -> [(answer: String, meaningID: UUID?)] {
        switch direction {
        case .enToKo:
            return word.coreMeanings.flatMap { meaning in
                [(meaning.text, meaning.id)]
                    + meaning.aliases.map { ($0.text, meaning.id) }
            }
        case .koToEn:
            return [(word.spelling, nil)]
        }
    }

    private func suggestionDistance(for value: String) -> Int {
        value.count >= 7 ? 2 : 1
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let replacement = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(insertion, deletion, replacement))
            }
            previous = current
        }
        return previous[right.count]
    }
}

public struct StudyCalendar: Sendable {
    public let timeZone: TimeZone

    public init(timeZone: TimeZone = TimeZone(identifier: "Asia/Seoul")!) {
        self.timeZone = timeZone
    }

    public func startOfDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    public func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    public func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }
}

public struct ProgressPolicy: Sendable {
    public let studyCalendar: StudyCalendar
    public let successDayRequirement: Int
    public let recentFailureWindow: Int
    public let maximumFailureCheck: Int

    public init(
        studyCalendar: StudyCalendar = StudyCalendar(),
        successDayRequirement: Int = 3,
        recentFailureWindow: Int = 14,
        maximumFailureCheck: Int = 3
    ) {
        precondition(successDayRequirement > 0)
        precondition(recentFailureWindow >= 0)
        precondition(maximumFailureCheck > 0)
        self.studyCalendar = studyCalendar
        self.successDayRequirement = successDayRequirement
        self.recentFailureWindow = recentFailureWindow
        self.maximumFailureCheck = maximumFailureCheck
    }

    public func state(
        for word: Word,
        attempts: [Attempt],
        asOf date: Date? = nil
    ) -> ReviewState {
        var state = ReviewState()
        let chronologicalAttempts = attempts.sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt < $1.occurredAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        for attempt in chronologicalAttempts {
            state.lastAttemptAt = attempt.occurredAt

            switch attempt.judgement {
            case .incorrect, .unknown:
                state.failureCheck = min(state.failureCheck + 1, maximumFailureCheck)
                state.activePriority = max(state.activePriority, state.failureCheck)
                state.latestWrongDirection = attempt.direction
                state.latestWrongAt = attempt.occurredAt
                if attempt.direction == .enToKo {
                    state.enToKoStreak = 0
                } else {
                    state.koToEnStreak = 0
                }
            case .correct:
                let day = studyCalendar.dayKey(for: attempt.occurredAt)
                switch attempt.direction {
                case .enToKo:
                    state.enToKoStreak += 1
                    if let meaningID = attempt.matchedMeaningID,
                       word.coreMeanings.contains(where: { $0.id == meaningID }) {
                        state.coreMeaningSuccessDays[meaningID, default: []].insert(day)
                    }
                case .koToEn:
                    state.koToEnStreak += 1
                    state.koToEnSuccessDays.insert(day)
                }
                if state.enToKoStreak >= 2 && state.koToEnStreak >= 2 {
                    state.activePriority = max(state.activePriority - 1, 0)
                    state.enToKoStreak = 0
                    state.koToEnStreak = 0
                }
            }
        }

        let evaluationDate = date ?? chronologicalAttempts.last?.occurredAt ?? word.createdAt
        if masterySatisfied(for: word, state: state, asOf: evaluationDate) {
            state.masteredOn = studyCalendar.startOfDay(for: evaluationDate)
        }

        return state
    }

    public func progress(
        for word: Word,
        attempts: [Attempt],
        asOf date: Date? = nil
    ) -> WordProgress {
        WordProgress(
            word: word,
            attempts: attempts,
            reviewState: state(for: word, attempts: attempts, asOf: date)
        )
    }

    public func recording(_ attempt: Attempt, in progress: WordProgress) -> WordProgress {
        precondition(attempt.wordID == progress.word.id, "Attempt must belong to the progress word.")
        let attempts = progress.attempts + [attempt]
        return self.progress(for: progress.word, attempts: attempts)
    }

    public func isMastered(_ progress: WordProgress) -> Bool {
        progress.reviewState.isMastered
    }

    private func masterySatisfied(
        for word: Word,
        state: ReviewState,
        asOf date: Date
    ) -> Bool {
        guard !word.coreMeanings.isEmpty else { return false }
        let allMeaningsSatisfied = word.coreMeanings.allSatisfy {
            (state.coreMeaningSuccessDays[$0.id]?.count ?? 0) >= successDayRequirement
        }
        guard allMeaningsSatisfied,
              state.koToEnSuccessDays.count >= successDayRequirement else {
            return false
        }

        guard let latestWrongAt = state.latestWrongAt else { return true }
        var components = DateComponents()
        components.day = -recentFailureWindow
        let failureThreshold = Calendar(identifier: .gregorian).date(
            byAdding: components,
            to: studyCalendar.startOfDay(for: date)
        )!
        return latestWrongAt < failureThreshold
    }
}
