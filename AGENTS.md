# Vocab Agent Contract

This file is the repository entry point for Codex and review agents.

## Workspace

- Canonical root: `/Users/swainyun/Desktop/Project/Vocab`.
- Inspect `git status --short` before editing and preserve unrelated changes.
- Edit Swift/Xcode sources directly with patches. Do not use Python as a
  substitute for source editing.
- Load `Docs/SwiftStyleGuide.md` before editing or reviewing Swift. Run
  `script/swift_style_check.sh` for every Swift change.
- Select verification with `script/verify_changed.sh`; expand it only when
  persistence, shared contracts, project settings, or release acceptance
  require broader coverage.

## Agent Policy

- The Codex main agent owns analysis, implementation, tests, documentation and
  user communication.
- Subagents must never modify files. A maximum of one Auditor subagent may be
  used, only after the main agent has produced a reviewable change.
- Code, persistence, sync, security, data-loss-sensitive, release, and harness
  changes require the Auditor before completion.
- Simple questions, inspection-only work, and command-only operations do not
  require an Auditor.
- The Auditor reviews the actual diff and verification evidence. A rejection
  returns work to the same main agent; the same Auditor is reused for re-review.
- For Swift changes, the Auditor also applies the contextual conventions that
  cannot be safely linted: early-exit `guard` use, loop choice, naming, actor
  boundaries, architecture direction, and test credibility.
- Rejection count is diagnostic only. There is no fixed retry limit: continue
  rework and review until approval, or ask the user only when a genuine blocker
  requires a product decision or external-state change.
- Main and Auditor IDs must differ. Auditor approval is bound to a hash of the
  complete Git worktree; any later repository change requires another review.
- No Director, Executor, Monitor, or Recorder subagents may be spawned.

## Closed-Loop

The enforceable flow is:

`Main implementation -> Auditor review -> Main rework when rejected -> Main close`

Use `script/closed_loop_pipeline.sh` for work requiring an Auditor. Start in
`transient` mode for ordinary code changes and `durable` mode only for
architecture, data policy, security, migration, deletion, or harness decisions
that future work must consult.

Durable decisions live in `Docs/ClosedLoop/records/` and are indexed by both
`Docs/ClosedLoop/INDEX.md` and `Docs/ClosedLoop/index.json`. Read the index
first and load only records whose scope intersects the task.

Durable Auditor approvals live in `Docs/ClosedLoop/audits/`; the local
registration/hash chain remains under `.git/closed-loop-pipeline/completed/`.

## Product Decisions

- Loose words remain outside daily-set membership.
- Today and Mixed test candidate pools include loose words while retaining the
  recent daily set as the majority source.
- Explicit selected-set tests contain only that selected set.
