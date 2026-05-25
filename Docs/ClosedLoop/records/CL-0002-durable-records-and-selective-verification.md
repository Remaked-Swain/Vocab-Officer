# CL-0002: Durable Records And Selective Verification

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-05-25 (Asia/Seoul) |
| Scope | `Docs/ClosedLoop/`, `script/verify_changed.sh`, Closed-Loop operation |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | 2026-08-23 |

## Problem

Agent completion messages are not durable project memory, and rerunning every
test for records-only or narrowly scoped changes spends time without improving
proof quality.

## Decision

- Persist loop decisions under `Docs/ClosedLoop` in source control.
- Require only `INDEX.md` as an initial read; load records by scope.
- Keep active decisions accessible, archive superseded records after a review
  window and delete only non-authoritative noise under the policy in
  `README.md`.
- Select verification from changed ownership boundaries using the executable
  single source of truth, `script/verify_changed.sh`; use the complete suite for cross-layer or
  release-acceptance changes.

## Monitor Findings And Resolution

| Finding | Resolution |
| --- | --- |
| Decisions existed only in agent output. | Add a durable index and scoped source-controlled records. |
| Read/archive/delete behavior was undefined. | Define scoped loading, protected classes, archive reviews and index tombstones. |
| Tests were selected manually without an executable impact map. | Add `script/verify_changed.sh` as the single executable map with class-level XCTest selection and escalation rules. |
| Raw results had no retention boundary. | Keep compact evidence in records while build/result artifacts remain regenerable and Git-ignored. |

## Evidence

- The persistent index and records replace reliance on agent lifecycle output.
- `script/verify_changed.sh --plan` fixtures demonstrate that documentation-only
  changes do not invoke application XCTest.
- Syntax checks and focused command-plan checks validate the workflow script.

## Verification Selected For This Decision

The changed files are process documentation and the new verification scripts.
The appropriate initial proof is shell syntax validation plus `--plan`
selection checks; running unrelated application XCTest is intentionally
omitted. A final broad regression run is required only if this loop also
changes application code or release acceptance.

## Limitation

No UI automation target currently exists. Presentation changes therefore
require a macOS build and a stated manual flow check unless a future record
adds UI test coverage.
