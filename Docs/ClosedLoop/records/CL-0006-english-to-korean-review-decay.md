# CL-0006: English-to-Korean Review Decay

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-05-28 (Asia/Seoul) |
| Scope | `Vocab/Domain/`, `Vocab/Application/`, `VocabTests/`, `Docs/ClosedLoop/` |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | Retain while the review scheduler exists |

## Decision

Vocab users primarily run English-to-Korean tests, so review priority must be able
to decay through that real routine without requiring Korean-to-English sessions.

## Rules

- `failureCheck` remains a historical difficulty record and does not decrease
  after correct answers.
- `activePriority` remains the review eligibility signal.
- The previous balanced rule still applies: when English-to-Korean and
  Korean-to-English streaks both reach 2, reduce `activePriority` by 1 and reset
  both streaks.
- New practical rule: when English-to-Korean streak reaches 2, reduce
  `activePriority` by 1 and reset only the English-to-Korean streak.
- Review sessions must include only active words with `activePriority > 0`.

## Verification

- `./script/verify_changed.sh Vocab/Domain/StudyPolicies.swift Vocab/Application/LearningCoordinator.swift VocabTests/Domain/StudyPoliciesTests.swift VocabTests/Application/LearningCoordinatorTests.swift`
- `./script/build_and_run.sh --install-verify`
