# CL-0012: Sequential Agent Handoffs

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-06-28 (Asia/Seoul) |
| Scope | `Docs/ClosedLoop/`, `script/closed_loop_pipeline.sh`, Closed-Loop role scheduling and handoff state |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while Codex Closed-Loop workflow exists |

## Problem

Starting independent role work in parallel allows Monitor or Recorder activity
to proceed without the exact output it must review. Completion messages alone
do not prove which artifact crossed a handoff, and concurrent updates can
corrupt or bypass an informal workflow state.

## Decision

- Roles are created one at a time, just in time, in this exact flow:
  `Director -> Executor -> Monitor -> original Executor on reject -> Recorder
  on approve -> Director close`.
- Parallel independent role execution is prohibited. The orchestrator closes
  the current role execution after its artifact is accepted, and only then
  spawns and registers the next role.
- `start` opens Director without registering any identity. Every active stage
  requires a separate just-in-time `register-role`; future-role and duplicate
  registration are rejected.
- Each successor registration requires the exact predecessor artifact SHA-256
  as a handoff token. Registration immediately re-hashes that artifact and
  requires the current file hash, stored hash and token to match. Stale,
  invented or post-submission-mutated handoffs are rejected.
- State records registration timestamp/order and an ordered artifact chain
  containing previous SHA-256, artifact SHA-256 and cumulative chain SHA-256.
  Each operation verifies the active actor ID against the latest registration,
  and every artifact records the registration order and actor ID that produced
  it.
- Monitor `reject` reactivates the original Executor ID and execution context;
  a replacement Executor cannot register. Monitor `approve` advances to
  Recorder.
- A run permits at most three Monitor rejections. A fourth rejection is
  rejected by the state machine.
- Recorder must submit a non-empty canonical file directly under
  `Docs/ClosedLoop/records/CL-*.md`. Director close requires its ID and exact
  `records/CL-*.md` link on the same `INDEX.md` row, its exact
  project-relative path in `index.json`, plus successful
  `script/closed_loop_records.sh validate`.
- Per-run mutation locks serialize concurrent commands. State updates use a
  temporary file, flush, `fsync`, and same-directory atomic rename.
- Successful Director close removes temporary run state.
- Missing or empty artifacts, wrong tokens, changed Executor identity, wrong
  roles and skipped stages fail without advancing state.
- Changed-path verification selects only the checks required by the affected
  ownership boundaries. This process-only change therefore avoids unrelated
  XCTest work and saves agent tokens and elapsed time without weakening the
  pipeline and record checks selected for this scope.

## Partial Supersession

This record partially supersedes:

- `CL-0002` only for any implication that four roles may be started
  independently before predecessor evidence exists.
- `CL-0007` only for its instruction to pass bootstrap facts to pre-spawned
  agents; bootstrap facts are now passed just in time when each eligible role
  starts.

`CL-0002` retention and verification selection remain active. `CL-0007`
canonical-root, sandbox, dirty-worktree and Swift/Xcode-first rules remain
active.

## Evidence

- `script/closed_loop_pipeline.sh --self-test` exercises a complete approval
  flow and a three-rejection round trip in isolated temporary directories.
- The self-test also rejects future-role and duplicate registration, stale and
  invented handoff tokens, predecessor artifact mutation, stage skipping,
  empty artifacts, replacement Executor identity, a fourth rejection and a
  held concurrent lock.
- Its isolated project fixture proves Recorder canonical-path enforcement,
  post-submit hash stability, exact human and JSON index paths, ordered
  registration/hash chain state and injected validator failure without
  changing the repository ledger.
- Successful self-test closes verify that both temporary run states are
  removed.
- `script/verify_changed.sh --self-test` confirms process changes select the
  pipeline self-test and decision-record validation without selecting XCTest.
- `script/closed_loop_records.sh validate` confirms reciprocal partial
  supersession metadata and index integrity.

## Monitor Approval

The Monitor approved the current implementation diff with no remaining
blocking finding. Recorder review confirmed that the approved behavior and
limitations are represented by this record and both index entries.

## Verification Selected For This Decision

Shell syntax checks, both harness self-tests, Closed-Loop record validation,
changed-file verification planning and `git diff --check` cover this
process-only change. Application XCTest is intentionally omitted because no
app or Xcode project behavior changed.

## Limitation

The shell cannot prevent Codex or another external orchestrator from spawning
or retaining agents outside this API. The orchestrator must enforce agent
lifecycle timing; pipeline role registration and hash tokens enforce and audit
the repository-local handoff boundary.
