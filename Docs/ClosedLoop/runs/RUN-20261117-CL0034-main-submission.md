# RUN-20261117-CL0034 Main Submission

## Scope

Implement approved `CL-0034` terminal mastery and automatic retirement without
committing, pushing or installing before the user's phase-three approval.

## Implementation

- Added explicit `active`, `consolidating` and terminal `masteredV2` states.
- Preserved persisted legacy `mastered` as a migration-only value that becomes
  consolidation without deletion.
- Added the five-date, 45-day evidence-span and 30-day final-interval formula.
- Kept direction, test mode and question format out of mastery eligibility.
- Reassigned existing spaced maintenance to consolidation.
- Added off-main automatic retirement workers and nonblocking progress status
  on macOS and iOS.
- Scrubbed identifying word, meaning, attempt, review and memory-aid content;
  removed session references; retained only unlinkable aggregate counts and
  per-record tombstones.
- Extended incremental and full CloudKit reconciliation to the new child
  tombstones and excluded deleted attempts from replay.
- Batched retirement by UUID set so each related record family is scanned at
  most once per cleanup run.

## Verification

- `script/swift_style_check.sh`: passed.
- `git diff --check`: passed.
- `script/closed_loop_records.sh validate`: 38 records, passed.
- Focused `StudyPoliciesTests` and four changed coordinator regressions: passed.
- macOS Debug build with signing disabled: passed.
- generic iOS Debug build with signing disabled: passed.
- No full test suite was run; verification follows the user's explicit
  change-scoped test requirement.

## Audit Request

Review the complete uncommitted diff read-only. Prioritize data-loss and
resurrection risk, legacy-store compatibility, CloudKit/recovery propagation,
actor isolation, main-thread blocking, lifecycle correctness, algorithmic
complexity, Swift conventions, and whether tests genuinely enforce the new
policy. Approve only when no actionable finding remains.
