# Vocab Agent Contract

This file is the repository entry point for Codex and review agents.

## Workspace

- Canonical root: `/Users/swainyun/Desktop/Project/Vocab`.
- Inspect `git status --short` before editing and preserve unrelated changes.
- Edit Swift/Xcode sources directly with patches. Do not use Python as a
  substitute for source editing.
- Load `Docs/SwiftStyleGuide.md` before editing or reviewing Swift. Run
  `script/swift_style_check.sh` for every Swift change.
- Before running unit tests or platform builds, review the changed logic for
  time and space complexity, cache lifetime, architecture direction, SOLID,
  Clean Code and readability. Resolve avoidable regressions first and record
  any accepted tradeoff or residual risk in the relevant decision evidence.
- Performance and readability are acceptance criteria for every code change,
  even when the user does not call them out explicitly.
- Before loading detailed project documents, run `script/route_context.sh`
  with `--intent inspect|change`, the request's task tags and known changed
  paths. Use `--list-tasks` when the available tags are unclear, then read only
  the returned documents.
- Select verification with `script/verify_changed.sh`; expand it only when
  persistence, shared contracts, project settings, or release acceptance
  require broader coverage.
- Before a work stage is declared complete, run only focused tests. Full
  platform builds require prior user approval during an active stage; use
  `script/verify_changed.sh --final` only after the stage is complete.
- Build-and-reinstall is a final-stage operation only. Never run
  `script/build_and_run.sh --install-verify` during implementation or review.

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
`Docs/ClosedLoop/INDEX.md` and `Docs/ClosedLoop/index.json`. The context router
is the normal loading entry point. Read the full index only when editing the
durable ledger, investigating historical or superseded behavior, or when the
router explicitly returns it.

Durable Auditor approvals live in `Docs/ClosedLoop/audits/`; the local
registration/hash chain remains under `.git/closed-loop-pipeline/completed/`.

## Product Decisions

- The product has one normalized-headword vocabulary, not daily or loose sets.
- Intake accepts any positive count and merges meanings into the existing SOT.
- Today uses the latest registration day when today has no intake; Review and
  Mixed retain spaced review and fair whole-library rotation.
- Legacy set entities remain persistence-only until a separately verified
  SwiftData and CloudKit migration removes them.
