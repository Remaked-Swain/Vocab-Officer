# CL-0035: Terminal Mastery Rework Submission

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-11-18 (Asia/Seoul) |
| Scope | immutable Main evidence for RUN-20261117-CL0034 re-audit |
| Review | same read-only Auditor as CL-0034 |
| Archive review | retain with CL-0034 |

## Resolved Findings

- Legacy `mastered` replay now creates a durable consolidation evidence
  boundary and cannot reuse historical attempts for terminal retirement.
- Previously tombstoned words, meanings, attempts, review state and memory-aid
  records are scrubbed even when deletion timestamps are equal.
- Word tombstones sanitize stale session UUID references during direct,
  incremental and full reconciliation.
- Deleted attempts retain their original session key, so snapshot validation
  and restore remain structurally valid while identifying answer content is
  removed.
- Cleanup uses a pending latch and delayed retry; notifications arriving during
  a worker run are not lost.
- Exact 45/30 acceptance, 44/29 rejection, legacy reconcile, detached deleted
  meaning scrub, stale-session reimport and cleanup snapshot round-trip are
  covered by focused regressions.

## Verification

- Swift style and whitespace checks passed.
- Focused policy, coordinator and CloudKit reconciliation tests passed.
- macOS Debug and generic iOS Debug builds passed with signing disabled.
- The full test suite was intentionally not run under the user's scoped-test
  requirement.

The same read-only Auditor must review the complete uncommitted diff and either
approve it or return another actionable rejection.
