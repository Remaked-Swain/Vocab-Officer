# CL-0009: Previous-Set Re-exposure In Review Mode

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-06-12 (Asia/Seoul) |
| Scope | `Vocab/Application/`, `Vocab/Presentation/`, `VocabTests/`, `Docs/ClosedLoop/` |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while review-session selection exists |

## Clarified Boundary

The requested behavior clearly requires review sessions to repeat recently
learned set words even when they are not failure-based review candidates.
The request did not define a ratio or the meaning of "previous" when there is
no set for the current day.

This decision defines those ambiguous points as follows:

- Failure-based review remains primary and contributes at most 14 initial
  questions.
- The immediately previous daily set contributes at most 6 active,
  non-deleted words.
- When no current-day set exists, the most recent set before the reference
  date is both the previous set and the reference fallback.
- Future-dated sets are never selected.

## Decision

A review session contains at most 20 unique words in this order:

1. Up to 14 candidates eligible under the existing review-priority rules.
2. Up to 6 active, non-deleted words from the immediately previous daily set.
3. Remaining eligible review candidates.
4. The existing reference-set fallback.

Previous-set and reference fallback words do not require
`activePriority > 0`. Their purpose is repeated exposure, not failure
classification. Duplicate SOT identifiers are skipped across every stage.
The previous-set pool uses the existing fair-presentation ordering.

Set recency is determined by `seoulDay`, then `createdAt`, then stable UUID
ordering. If all pools are empty, no `TestSessionRecord` is persisted.

## Preserved Contracts

- `CL-0005`: maximum 20 unique questions and candidate-free session safety.
- `CL-0006`: review eligibility, failure checks, streaks, and priority decay.
- `CL-0008`: loose-word test selection.
- Re-exposure alone does not change attempts, mastery, streaks,
  `failureCheck`, or `activePriority`; only answer processing changes them.

## Excluded Scope

- No scheduler scans or rotates through every historical set.
- No long-term forgetting score is added.
- No test-history deletion or cleanup behavior is changed.
- `오늘 신규`, `세트 선택`, `혼합`, and `낱개` selection ratios are unchanged.

## Verification

- Focused coordinator tests cover 14 failure candidates plus previous-set
  recurrence, a missing current-day set, the six-word recurrence cap with a
  small failure pool, future-set exclusion, uniqueness, and fallback filling.
- The existing review-priority, priority-decay, and other session-mode tests
  remain in the selected verification scope.
- Changed-file verification passed with the selected coordinator and policy
  tests, followed by a successful Debug build.
- The Release build was installed at `/Applications/Vocab.app`, and strict
  code-signature verification passed.

## Limitation

This policy provides short-term repetition from only the immediately previous
set. It intentionally does not prevent long-term memory decay across all older
sets, because that broader scheduling and history-deletion interaction was
explicitly excluded from this change.

## Relationships

This decision extends `CL-0005` and `CL-0006`. It preserves `CL-0008` and does
not supersede existing mastery or review-decay rules.
