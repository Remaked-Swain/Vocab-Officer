# CL-0008: Loose Word Testing

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-06-10 (Asia/Seoul) |
| Scope | `Vocab/Application/`, `Vocab/Presentation/`, `VocabTests/`, `Docs/ClosedLoop/` |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while loose-word intake and testing exist |

## Decision

- Provide a separate `낱개` test mode.
- A loose-word candidate is an active, non-deleted SOT word whose identifier
  is not referenced by any `DailySetItemRecord`.
- Order loose-word candidates with the existing fair-presentation policy and
  select at most 20 unique words per session.
- Preserve the existing selection behavior and ratios for `오늘 신규`,
  `세트 선택`, `복습`, and `혼합`.
- Candidate-free starts fail before a `TestSessionRecord` is persisted.

## Rationale

Loose words previously had valid vocabulary and progress records but no daily
set link. They could not enter a first test session, so they could not acquire
attempt history or review priority. Mixing them into an existing mode would
change the established daily-set and review contracts. A dedicated mode makes
the scope explicit and keeps the other modes stable.

## Verification

- Added focused coordinator tests for a reduced one-word loose session,
  exclusion of daily-set words with unseen-word priority across repeated
  sessions, and candidate-free session safety.
- `./script/verify_changed.sh Vocab/Application/LearningCoordinator.swift Vocab/Presentation/TestViews.swift VocabTests/Application/LearningCoordinatorTests.swift`
  passed its selected `LearningCoordinatorTests`, `StudyPoliciesTests`, and
  Debug build.
- `./script/build_and_run.sh --install-verify` passed the Release build,
  signing, bundle validation, Launch Services registration, and local
  installation verification.

## Monitor Findings

The Monitor approved the separate-mode design. The implementation fetches all
`DailySetItemRecord` identifiers directly so even an orphaned item prevents its
word from being misclassified as loose.

## Limitations

- Words already linked to a daily set are not shown in the loose mode.
- Inactive, deleted, and Mastered words are excluded by the active-word query.
- Long-term distribution remains governed by the existing `fairOrder` policy.

## Relationships

This decision extends `CL-0001` and `CL-0005`. It does not change the review
eligibility and decay rules in `CL-0006`.
