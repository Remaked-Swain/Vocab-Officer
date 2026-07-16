# CL-0018: Run-Scoped Role Agent Reuse

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-15 (Asia/Seoul) |
| Scope | `Docs/ClosedLoop/`, `Docs/Verification.md`, `script/closed_loop_pipeline.sh`, Closed-Loop role-agent lifecycle and token efficiency |
| Agents | Director, Executor, Monitor, Recorder, Codex main agent |
| Archive review | retain while Codex Closed-Loop workflow exists |

## Problem

Closing a healthy role agent after every handoff and later resuming or
recreating it spends time and tokens restoring its connection and context. It
also weakens continuity across Monitor rejection and Executor rework even
though the pipeline already requires one stable identity per role.

## Decision

- Role execution remains strictly sequential. Only the role opened by the
  pipeline may receive an active instruction or mutate its owned artifact.
- Each role is spawned at most once per run, just in time when that role first
  becomes eligible. Its agent ID is stored in a run-local role map.
- An accepted artifact makes the predecessor idle; it does not terminate that
  agent. Later turns use the same agent ID with a concise delta and the current
  handoff token. Full history must not be replayed when the retained context is
  healthy.
- `register-role` is a logical activation boundary. Its first call binds the
  role identity and later calls reactivate that same retained identity.
- Monitor rejection returns work to the retained Executor. A later Monitor
  review uses the retained Monitor. Director close likewise returns to the
  original Director.
- `resume_agent` is reserved for recovery from an interrupted connection. It
  is not part of a normal handoff.
- Healthy role agents are closed exactly once after Monitor approval,
  Recorder persistence and successful validated Director close. Explicit run
  cancellation, unrecoverable agent failure or a hard concurrency-capacity
  requirement may force earlier closure; the run evidence must record why.
- Inactive retained agents stay idle. Retention does not permit parallel role
  work, speculative review or future-role execution.

## Partial Supersession

This record partially supersedes `CL-0012` only for its requirement to close a
healthy role execution before spawning the successor. `CL-0012` remains active
for ordered role activation, just-in-time first spawn, stable identity,
artifact hash tokens, rejection routing, concurrency locking and validated
Recorder close. `CL-0015` continues to govern whether a Closed-Loop is used and
the Codex main-agent orchestration boundary.

## Evidence

- Pipeline state schema 3 declares `agentLifecyclePolicy` as
  `run-scoped-reuse`.
- Pipeline self-test verifies that repeated Executor and Monitor activations
  retain one actor ID and are recorded as `reactivated` after first binding.
- Shell syntax, pipeline self-test, record-ledger validation and whitespace
  validation cover this process-only change. Application XCTest is omitted
  because no Swift, persistence or UI behavior changed.

## Limitation

Repository scripts cannot invoke or prevent external `spawn_agent`,
`resume_agent` or `close_agent` operations. They bind and audit stable role
identities; the Codex orchestrator must keep the mapped sessions alive and
perform terminal cleanup.
