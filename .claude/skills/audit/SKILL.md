---
name: audit
description: Get the single read-only auditor's approval for a finished Vocab change (code, persistence, sync, security, deletion, release or harness) before committing. Use after implementation and focused verification are complete.
---

The approval is bound by hook to the exact worktree; `git commit` of gated
paths is blocked until it matches. Finish every edit first.

1. Confirm `verify` checks pass and any changed policy is reflected in the
   matching `.claude/rules/*.md`.
2. Spawn `auditor` once with a short Main report:
   - request and accepted interpretation
   - changed paths and notable design choices
   - exact verification commands and results, omissions
   - known limitations or pending user approval
3. `Decision: reject` → fix every finding, re-verify, then `SendMessage` the
   same auditor with what changed. Never spawn a second auditor; no retry
   limit. Stop and ask the user only for a genuine product decision.
4. `Decision: approve` → change nothing else, then commit. The approval binds
   the whole worktree tree, so it may be split into several logical commits
   without re-review. Commit messages state the decision rationale (they
   replace separate decision records) and end with `Audit: approved`.

Verdict history: `.git/claude-audit/log.tsv`; last verdict:
`.git/claude-audit/last-verdict.md`.
