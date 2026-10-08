# CL-0029: Restarted Source Numbering And Adaptive OCR

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-10-08 (Asia/Seoul) |
| Scope | printed vocabulary numbers, OCR page assembly, missing-number diagnostics, daily intake |
| Review | main-agent verification; user explicitly allowed completion without a subagent |
| Archive review | retain while numbered paste or image OCR intake exists |

## Problem

Vocabulary source material can restart its printed sequence at `0001`. Printed
numbers are not globally unique, and a new edition can use a layout that differs
from the original fixed two-column page.

## Decision

- A printed number is transient source metadata. It is never a `WordRecord`
  identity or SwiftData uniqueness key.
- Canonical words continue to use UUID identity and normalized headword SOT.
  Repeated headwords merge meanings while each daily-set occurrence keeps its
  own `DailySetItemRecord`.
- Multi-image OCR preserves user-selected page order. It does not globally sort
  rows by printed number.
- OCR infers column boundaries from number-token X-coordinate clusters rather
  than a fixed two-column split, and accepts four-to-eight-digit source numbers.
- Within each inferred column, a number token opens a vocabulary-card block
  that extends toward the next number. This supports both the legacy inline
  layout and the newer number/term/meaning three-line layout.
- Vision can merge the bold headword and adjacent pronunciation into one text
  observation. Formatting removes pronunciation artifacts while retaining
  multiword and hyphenated headwords.
- Missing-number diagnostics operate on contiguous input order. A non-increasing
  number starts a new sequence, so a restart is not reported as corruption.
- OCR output remains editable and passes through the existing parser and atomic
  daily-set save path.

## Safety And Performance

No SwiftData or CloudKit schema migration is introduced. Column inference and
card assembly operate only on one page's tokens, while Vision recognition,
downsampling and page processing remain off the main actor.

## Verification

Tests cover repeated `0001` values on separate pages, selected-page ordering,
number placement to the right of vocabulary content, reset-aware gap detection,
legacy two-column fixtures, noisy number recovery and the existing 100-row
recall fixture. The user-provided 1,668 x 2,388 reference screenshot is retained
as a test-only fixture; Vision plus formatting recovers all 20 numbered rows in
reading order on the current Mac.

## Limitation

Real-image coverage now includes the restarted-numbering three-line layout.
Any further materially different edition still requires its own representative
screenshot fixture before accuracy can be claimed.
