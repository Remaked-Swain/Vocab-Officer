# CL-0010: Parenthesized-Comma Meaning Tracking

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-06-17 (Asia/Seoul) |
| Scope | `Vocab/Application/`, `VocabTests/`, `Docs/ClosedLoop/` |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while correction and meaning-tracking behavior exists |

## Problem

The SOT can contain a single Korean meaning with a comma inside parentheses,
such as `(수학, 화학) 공식`. The intake splitter correctly stores that text as
one meaning, but the tracking guard treated any comma as a legacy multi-meaning
delimiter.

That mismatch hid the meaning from the English-to-Korean correction picker and
blocked `확정 후 다음`, because corrected Korean answers require a confirmed core
meaning identifier.

## Decision

Meaning trackability is determined by the same parenthesis-aware splitter used
for storage. A meaning is individually trackable when `MeaningTextSplitter`
returns exactly one value for that meaning text.

- `(수학, 화학) 공식` and `（배, 기차에） 타다` are single meanings and remain
  selectable as confirmed core meanings.
- Legacy combined meanings such as `첫 의미, 둘째 의미` remain untrackable.
- Automatic English-to-Korean judging, correction credit, and mastery progress
  use the same trackability rule.
- Paste parsing accepts Korean meanings that begin with fullwidth `（`, so OCR
  output can reach the same splitter path.

## Preserved Contracts

- `CL-0004`: paste intake remains the primary bulk-entry path.
- `CL-0005`: corrected English-to-Korean answers still require a confirmed
  core meaning before committing.
- `CL-0006`: review and mastery progress continue to exclude true legacy
  delimiter-combined meanings.

## Excluded Scope

- No automatic migration splits existing legacy combined meanings.
- No UI redesign is included; the existing picker is fixed by restoring the
  correct candidate set.
- No changes are made to session selection, review priority, deletion, or
  history cleanup.

## Verification

- Added regression coverage for parenthesized-comma correction credit.
- Added a guard that true legacy delimiter-combined meanings remain
  untrackable.
- Added paste-parser coverage for fullwidth parenthesized Korean meaning
  starts.
- `./script/verify_changed.sh Vocab/Application/LearningCoordinator.swift VocabTests/Application/LearningCoordinatorTests.swift`
  passed the selected `StudyPoliciesTests` and `LearningCoordinatorTests`.
- Release build and `/Applications/Vocab.app` code-signature verification
  passed.

## Limitation

Human display still joins multiple meanings with `, `, so a list containing
parenthesized commas can be visually ambiguous. The underlying SOT and edit
round trip remain parenthesis-aware.

## Relationships

This decision extends `CL-0004`, `CL-0005`, and `CL-0006`. It does not
supersede existing records.
