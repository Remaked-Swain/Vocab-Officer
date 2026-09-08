# CL-0027: Unbounded Auditor Rework

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-09-04 (Asia/Seoul) |
| Scope | Closed-Loop rejection and rework termination policy |
| Agents | Codex main agent, one read-only Auditor |
| Partially supersedes | CL-0025 (rejection-limit policy only) |
| Archive review | retain while Codex workflow uses this harness |

## Problem

The pipeline imposed a three-rejection limit that the user never requested.
It conflicted with the original requirement that review and rework continue
until the Auditor approves, and it could turn useful late findings into a
harness failure.

## Decision

- Auditor rejection count is diagnostic evidence only and has no upper bound.
- Every rejection returns control to the same Main identity, and re-review
  reuses the same read-only Auditor identity.
- The loop ends normally only after Auditor approval and Main close.
- A genuine blocker requiring a product decision or external-state change is
  reported to the user. Repetition count alone is never a blocker.
- The pipeline retains ordering, immutable artifacts, hash-chain handoffs,
  worktree-bound approval, and durable evidence safeguards.

## Evidence

- Pipeline self-tests complete five rejection/rework cycles before approval,
  proving that the former limit no longer terminates the run.
- Shell syntax, pipeline self-tests, record-validator tests, ledger validation,
  and verification-selection tests cover the harness change.

## Limitations

Repository scripts cannot decide whether an external dependency truly requires
user action. Main must explain the concrete blocker rather than infer one from
the number of review cycles.
