# Vocab — Claude Code Contract

This file is the only always-loaded rule set. Area rules live in
`.claude/rules/*.md` and load automatically when you touch their paths; read
one explicitly when a change affects its area without touching those paths.

## Product

- macOS + iOS vocabulary trainer, SwiftUI + SwiftData, OS 26+. Bundle
  `com.swainyun.Vocab`; root `/Users/swainyun/Desktop/Project/Vocab`.
- One normalized-headword vocabulary, no daily or loose sets. Intake accepts
  any positive count and merges meanings into the existing SOT.
- Today uses the latest registration day when today has no intake; Review and
  Mixed keep spaced review and fair whole-library rotation.
- Legacy set entities stay persistence-only until a separately verified
  SwiftData and CloudKit migration removes them.
- Layers: Domain (pure, no SwiftUI/SwiftData/CloudKit) ← Application ←
  Data/Infrastructure/Presentation. UI never decides grading, mastery,
  deletion or sync policy. macOS and iOS share business rules.

## Workflow

1. Check `git status --short`; preserve unrelated changes.
2. Before tests, review the change for time/space complexity, cache lifetime,
   architecture direction, SOLID and readability. Performance and readability
   are acceptance criteria for every change.
3. Verify with the `verify` skill: focused tests only during a stage. Full
   builds need user approval until the stage is complete; `--final` and
   `script/build_and_run.sh --install-verify` are final-stage only.
4. Code, persistence, sync, security, deletion, release and harness changes
   need the `auditor` subagent before commit; use the `audit` skill.
   Questions, inspection and command-only work need no Auditor.
5. When a change alters a recorded policy, update it in the same change.
   A new, changed or removed convention from the user goes through the
   `convention` skill.

## Where Conventions Live

| Kind | Place | Enforced by |
| --- | --- | --- |
| Area design and contextual code rules | `.claude/rules/<area>.md` (`paths:` scoped) | auto-load + Auditor |
| Objective, pattern-checkable bans | `.claude/lint/swift.rules` (+ `baselines/`) | lint on edit and on `git commit` |
| Product, workflow, Git, privacy | this file | always loaded |

Rules hold current truth only. A failed approach worth not repeating goes in
its area rule under `## Pitfalls` as one line with the commit hash.

## Git

- One work unit maps 1:1:1 to an issue, a branch and a PR. Smaller pieces of
  the same unit are separate commits on that branch, never separate or
  stacked branches and PRs.
- Commits: `type(scope): imperative summary` (`feat`, `fix`, `refactor`,
  `docs`, `chore`, `test`); the body states why. Audited commits end with
  `Audit: approved`. One logical change per commit.
- PRs target `develop`; the description lists changed areas, the
  improvement achieved (measured before/after where possible), its limits
  and residual risk, the reason behind each design decision (including
  alternatives considered and rejected), and the verification run. Issues
  state observed vs expected behavior.

## Agents And Tools

- The main session alone edits files. The only subagent is `auditor`, once
  per change; after a rejection continue it with `SendMessage`. Do not use
  Explore, Plan, general-purpose or fork agents for repository work.
- Edit Swift, Xcode and harness files with Edit/Write, never with Python or
  `sed -i` rewrites.
- Hooks: a `.swift` or lint-rule edit runs the lint (failure = blocking
  finding); the auditor's verdict is recorded under `.git/claude-audit/`
  bound to the worktree tree, and `git commit` of gated paths is blocked
  without a matching approval; loaded rule files are logged to
  `.git/claude-metrics/`. Never write under `.git/claude-*` yourself.

## Privacy

Never commit vocabulary payloads, SwiftData/SQLite stores, `.tsv/.csv/.jsonl`
intake files, secrets, signing material, build or test output, Xcode user
state, or absolute local paths in evidence.

## Context Budget

Skip `build-ios/`, `device-build/`, `release-build/`, `test-build/`,
`performance-build/` and result bundles unless diagnosing that output.
