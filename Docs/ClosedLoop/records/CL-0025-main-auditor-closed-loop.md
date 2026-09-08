# CL-0025: Main And Auditor Closed-Loop

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-09-03 (Asia/Seoul) |
| Scope | repository agent contract, Closed-Loop roles, audit evidence, pipeline enforcement and record validation |
| Agents | Codex main agent, one read-only Auditor |
| Supersedes | CL-0012, CL-0015, CL-0018 |
| Partially superseded by | CL-0027 (rejection-limit policy only) |
| Archive review | retain while Codex workflow uses this harness |

## Problem

The four-role pipeline duplicated analysis and context across Director,
Executor, Monitor, and Recorder agents. It spent substantial tokens restoring
agent context, sometimes encouraged parallel work, and conflicted with the
new requirement that the main agent implement changes while subagents are used
only for independent inspection.

## Decision

- The main agent owns analysis, implementation, verification, documentation,
  records, and user communication.
- At most one read-only Auditor subagent may be created. It reviews only after
  a complete Main artifact exists and cannot modify files.
- Code, persistence, sync, security, data-safety, release, and harness changes
  require an Auditor. Simple questions, read-only inspection, and command-only
  operations remain main-only.
- The enforced flow is `Main -> Auditor -> Main close`. Rejection returns to
  the same Main identity and re-review uses the same Auditor identity.
- Hash-token handoffs, immutable reviewed artifacts, atomic state updates,
  concurrency locking, stable identities, and a three-rejection cap were
  adopted here. CL-0027 later removes only that cap.
- Main and Auditor identities must differ. Approval binds both the immutable
  Auditor artifact and a SHA-256 of the complete tracked and untracked Git
  worktree; any post-review repository change requires re-review.
- Transient mode provides enforced review without permanent operational noise.
  Durable mode is reserved for decisions future sessions must consult and
  requires the Auditor-approved Main artifact to be a canonical indexed record.
- Record validation rejects unindexed decision files in addition to malformed,
  missing, duplicate, non-reciprocal, filename-mismatched, path-duplicated, or
  human/JSON index-inconsistent records.
- Production validation always uses the canonical repository root and bundled
  validator. Durable approval artifacts live under `audits/`, and completed
  hash-chain state remains in the local Git state directory.

## Product Decision Preserved

Loose words remain outside daily-set membership. They join Today and Mixed
test candidate pools independently, while explicit selected-set tests remain
limited to the selected set.

## Evidence

- Pipeline self-tests cover role order, one-Auditor identity binding, stale and
  modified handoffs, rejection/rework, replacement rejection, rejection cap,
  worktree hashing with external diff disabled, run-bound durable audit paths,
  completed-run immutability, schema-4 active-run chain migration, durable
  ledger enforcement, locking, and terminal cleanup.
- Record-validator self-tests reject duplicate paths, duplicate or human-only
  index rows, filename/ID mismatch, and unindexed decision files.
- Record validation covers the newly indexed CL-0024 record and this decision.
- Changed-path verification selects process tests for harness files and the
  relevant app tests for the existing intake and session-selection changes.

## Limitations

Repository scripts cannot create or constrain external Codex subagents. The
orchestrator must obey `AGENTS.md`; the pipeline supplies repository-local
identity and evidence enforcement.
