# CL-0033: Setless Vocabulary Registration

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-11-13 (Asia/Seoul) |
| Scope | vocabulary registration, registration-day grouping, session sources, legacy compatibility |
| Review | Main implementation and single read-only Auditor |
| Archive review | retain while vocabulary persistence or intake exists |

## Decision

- The product owns one vocabulary library, not daily word sets. Intake accepts
  any positive count from manual, paste or OCR input.
- `normalizedTerm` is the SOT merge key across nondeleted Active and Mastered
  words. Existing meaning normalization provides set-union semantics.
- An exact duplicate is a no-op. A newly added meaning reactivates a Mastered
  word because its expanded SOT has not yet been verified.
- `createdAt` is the immutable first-registration timestamp. Product grouping
  and recency compare only its `Asia/Seoul` `YYYY-MM-DD` projection.
- Deleted words do not participate in merge lookup; later registration creates
  a new UUID.
- Today uses the latest registration day when today has no intake. Review uses
  the immediately preceding registration day as a bounded re-exposure source.
  Mixed rotates across every active word using existing fairness summaries.

## Compatibility

`DailySetRecord` and `DailySetItemRecord` remain in the SwiftData and CloudKit
schema for additive compatibility with existing stores, snapshots and peers.
No current UI or registration path creates them. This avoids a destructive
migration while allowing a later cleanup only after all installed peers have
crossed a separately verified migration boundary.

## Complexity

Registration normalizes `I` input rows, performs one `O(W)` active-library
fetch, and unions meanings with hash sets in `O(I + W)`. This predictable scan
avoids repeated unindexed `IN` queries while the CloudKit-compatible schema
does not carry a new local-only index. Session and UI
registration-day grouping are one `O(W)` pass; candidate ordering retains the
existing `O(W log W)` bound. No attempt history scan was introduced.

## Verification

- 137-word intake succeeds without creating legacy set records.
- Duplicate registration preserves first date and exact Mastered duplicates.
- A genuinely new meaning reactivates Mastered while preserving one word SOT.
- Meaning-expansion reactivation survives attempt replay because only answers
  at or after the latest SOT revision can rebuild mastery evidence.
- Existing-word SOT revisions advance monotonically even when intake carries a
  backdated registration date.
- Today selects the newest registration day without any legacy set.
- Mixed excludes words registered after the requested session day across broad
  rotation, promotion and active-review paths.
- Focused coordinator regressions: 6 passed.
- Release scaling fixture at 3,379, 6,758 and 13,516 words passed; the complete
  performance test took 6.982 seconds on the current Mac after final rework.
- macOS and generic iOS 26 builds pass.
- Swift style and whitespace checks pass.
- The full test suite was intentionally not run because the user required
  change-scoped verification.

## Relationships

- Supersedes the 100-word set and selected-set product rules in `CL-0001`,
  `CL-0004`, `CL-0005`, `CL-0008` and `CL-0009`.
- Preserves `CL-0032` Mastered evidence and broad-rotation fairness.
- Preserves `CL-0016` by retaining legacy entities in the CloudKit schema.
