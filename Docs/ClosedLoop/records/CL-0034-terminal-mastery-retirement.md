# CL-0034: Terminal Mastery And Automatic Retirement

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-11-17 (Asia/Seoul) |
| Scope | consolidation, terminal mastery, automatic retirement, CloudKit deletion safety |
| Review | Main implementation and single read-only Auditor |
| Archive review | retain while learning lifecycle, deletion, CloudKit or recovery exists |

## Decision

- `active` (`학습 중`) is ordinary test eligibility.
- `consolidating` (`장기정착`) begins after correct outcomes on two distinct
  Seoul dates after the latest failure or SOT revision. It owns the existing
  spaced maintenance path and immediately returns to `active` after a wrong or
  unknown result.
- Terminal `masteredV2` (`암기완료`) requires five distinct eligible success
  dates, a first-to-final evidence span of at least 45 days, and at least 30
  days between the last two success dates. Mode, direction and typed versus
  multiple-choice format do not alter credit. Same-day repetitions count once,
  and exhaustive meaning coverage is not required.
- Existing persisted `mastered` is a legacy value. It migrates to
  `consolidating` and cannot be automatically deleted solely from its old
  classification.

## Retirement Safety

- A newly reached terminal status requests nonblocking background cleanup on
  both platforms. The UI reports delayed work after 200 ms and completion or
  retry state without disabling foreground interaction.
- Cleanup scrubs headword, meaning, answer, review and memory-aid content,
  removes the word UUID from sessions, and soft-deletes the word and every
  identifying child record.
- A tombstone is emitted for the word, meanings, attempts, review state,
  memory-aid cache and legacy set membership. Only an unlinkable daily count is
  retained.
- Tombstones are mirrored through CloudKit and included in the recovery
  snapshot graph. Reconciliation applies tombstones after imports and excludes
  deleted attempts from state replay, preventing an older peer from restoring
  identifying content or mastery state.

## Complexity

Candidate discovery uses the indexed persisted status and deleted marker.
Retiring `R` words builds one UUID set and scans each related record family at
most once, bounded by `O(W + I + S + M + A)` for words, legacy memberships,
sessions, memory aids and affected child records. Normal session generation
continues to use summary state and never scans full attempt history.

## Compatibility

No SwiftData property or CloudKit field is added. The new terminal raw value
distinguishes new evidence from legacy `mastered` data, so existing stores,
snapshots and peers remain readable without a destructive migration.

## Verification

- Five-date, 45-day and final-30-day policy boundaries are covered by focused
  domain tests, including post-failure evidence reset.
- Multiple-choice one-direction evidence reaches consolidation without
  requiring all meanings.
- Legacy `mastered` migrates without deletion even when old evidence would
  satisfy the new terminal formula.
- Automatic cleanup tests identifying-data scrub, session unlinking,
  unlinkable aggregate preservation and every resurrection tombstone type.
- Change-scoped macOS and iOS builds, Swift style, whitespace and one Auditor
  review are required before this record is closed.

## Relationships

- Partially supersedes `CL-0030`, `CL-0031` and `CL-0032` for the meaning of
  Mastered, qualification threshold, maintenance ownership and deletion.
- Preserves `CL-0031` and `CL-0032` Mixed quotas and fair-rotation rules, with
  their former Mastered-maintenance pool now interpreted as `장기정착`.
- Extends `CL-0016` and `CL-0020` with tombstoned automatic retirement in the
  mirrored and recovery stores.

## Audit History

The first read-only audit rejected the implementation pending protection from
legacy-evidence replay, scrubbing of already tombstoned children, stale-session
reference cleanup, snapshot-compatible deleted attempts, lossless single-flight
retry handling, and direct regression coverage for those paths. Main rework is
required before a second review by the same Auditor.
