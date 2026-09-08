# CL-0015: Director-Gated Closed-Loop Use

| Field | Value |
| --- | --- |
| Status | superseded |
| Date | 2026-07-14 (Asia/Seoul) |
| Scope | `Docs/ClosedLoop/`, `Docs/Verification.md`, Closed-Loop default-use policy and role lifecycle |
| Agents | Director, Executor, Monitor, Recorder, Codex main agent |
| Superseded by | CL-0025 |
| Archive review | retain while Codex Closed-Loop workflow exists |

> Historical record only. Its Director/Executor/Monitor/Recorder instructions
> must not be applied. Current work follows CL-0025 and AGENTS.md.

## Problem

The previous workflow text made four-role Closed-Loop the default even when a
task did not need durable multi-role review. That wastes tokens and elapsed
time, and it encourages role creation before there is a clear Director reason
for using the heavier workflow.

## Historical Decision

- Closed-Loop is not the default workflow. The Director decides whether to use
  it and records the use or non-use reason in the Director artifact.
- Use Closed-Loop when the task needs durable decision evidence, ordered
  multi-role review, auditable acceptance, explicit user instruction, changes
  to Closed-Loop policy/tooling, or high-risk behavior where independent review
  is worth the cost.
- Do not use Closed-Loop for simple inspection, command-only answers, routine
  single-agent edits, low-risk documentation fixes, or changes whose audit
  value does not justify Director, Executor, Monitor and Recorder handoffs.
- When used, the role order is:
  `Director analysis -> Executor change -> Monitor review -> Recorder record
  -> Director close`.
- On Monitor rejection, the same Executor identity and context performs the
  rework. A replacement Executor must not be created. Approval advances to
  Recorder.
- Executor, Monitor and Recorder must not be created concurrently. Each role is
  created only after the previous artifact is accepted and the pipeline opens
  the next role.
- Recorder is created only after Monitor approval and records the approved
  decision before Director close.
- During a Closed-Loop run, the Codex main agent must not directly change code
  or documentation. It only orchestrates role order, handoff tokens, token
  budget, sandbox state and verification visibility.

## Supersession

This record partially supersedes `CL-0012` only for the statement that
Closed-Loop should be used by default. The sequential handoff state machine,
hash-token requirements, same-Executor rejection path, Recorder validation and
repository-local enforcement limitations from `CL-0012` remained in force
until CL-0025 replaced the four-role workflow.

## Evidence

- `script/closed_loop_records.sh validate` confirms the indexed record ledger
  remains valid.
- `./script/verify_changed.sh Docs/ClosedLoop/README.md Docs/ClosedLoop/records/CL-0012-sequential-agent-handoffs.md Docs/ClosedLoop/INDEX.md Docs/ClosedLoop/index.json Docs/Verification.md Docs/ClosedLoop/records/CL-0015-director-gated-closed-loop.md`
  selected and ran the process-only verification for this documentation change.
- `git diff --check -- Docs/ClosedLoop/README.md Docs/ClosedLoop/records/CL-0012-sequential-agent-handoffs.md Docs/ClosedLoop/INDEX.md Docs/ClosedLoop/index.json Docs/Verification.md Docs/ClosedLoop/records/CL-0015-director-gated-closed-loop.md`
  found no whitespace errors.

## Monitor Approval

The Monitor first rejected the Executor artifact, then approved the original
Executor's rework. The approval found that `README.md` now states Director
startup, role-artifact approval before successor creation, the
`Director analysis -> Executor change -> Monitor review -> Recorder record ->
Director close` order, original-Executor reactivation on reject, no replacement
Executor, Recorder progression after approval, the Codex main-agent
orchestration boundary and the Closed-Loop use/non-use criteria.

Recorder review confirmed that `INDEX.md` and `index.json` consistently index
this record and that the approved process decision is represented without
creating a duplicate record.

## Verification Selected For This Decision

This is a process documentation and ledger change. Closed-Loop record
validation and changed-file verification cover the affected behavior. App
XCTest is intentionally omitted because no Swift, app runtime, persistence or
Xcode project behavior changed.

## Limitation

The repository scripts cannot prevent an external orchestrator from directly
editing files or spawning agents outside the pipeline. This policy makes that
responsibility explicit for the Codex main agent and leaves repository-local
handoff enforcement to `CL-0012`.
