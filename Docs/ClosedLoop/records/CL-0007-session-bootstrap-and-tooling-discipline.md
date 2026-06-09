# CL-0007: Session Bootstrap And Tooling Discipline

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-06-09 (Asia/Seoul) |
| Scope | `Docs/ClosedLoop/`, session bootstrap, sandbox awareness, project root handling, Swift/Xcode-first implementation workflow |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while Codex workflow exists |

## Problem

Agents sometimes start from the transient Codex thread working directory
instead of the canonical Vocab project root. In restricted sessions this causes
failed reads, missed writes, wrong verification scope and repeated rediscovery
of the same sandbox limitation. Some tasks also drift toward Python-based
source rewriting even though Vocab is a SwiftUI and SwiftData macOS app.

## Decision

- Treat `/Users/swainyun/Desktop/Project/Vocab` as the canonical project root
  for this application unless the user explicitly changes it.
- At the start of every agent-backed task, pass each agent the canonical root,
  current sandbox profile, whether project commands require escalation, current
  Git status and unrelated dirty files to preserve.
- Agents must not infer the project root from the transient Codex thread `cwd`
  when it differs from the canonical root.
- Source changes to Vocab app code should be Swift/Xcode-first: edit Swift,
  SwiftData, SwiftUI, Xcode project and shell harness files directly, then
  verify with focused XCTest, `xcodebuild`, `script/verify_changed.sh` and
  `script/build_and_run.sh` where applicable.
- Python is allowed for tooling, fixture generation, repository analysis and
  data inspection. It is not the default mechanism for modifying Swift source
  or Xcode project files.
- Verification must be selected from the changed-file scope. Do not run broad
  tests only because the session forgot the narrower path context.

## Monitor Findings And Resolution

| Finding | Resolution |
| --- | --- |
| Agents lose the target path and attempt work from the thread `cwd`. | Require canonical-root bootstrap before delegation or edits. |
| Restricted sandbox failures are rediscovered repeatedly. | Include sandbox profile and escalation requirement in every agent brief. |
| Dirty unrelated files can be accidentally mixed into commits. | Require pre-edit Git status and explicit preservation of unrelated changes. |
| Python rewrites can bypass Swift compiler feedback. | Prefer patch-based Swift edits and Xcode/XCTest verification for app source. |
| Verification can become too broad when context is missing. | Continue using `script/verify_changed.sh` with exact changed paths. |

## Evidence

- `Docs/ClosedLoop/README.md` now includes a session bootstrap checklist and
  Swift/Xcode-first tooling discipline.
- `Docs/ClosedLoop/INDEX.md` requires future agent-backed or app-editing tasks
  to apply this decision.
- `Docs/ClosedLoop/index.json` indexes this decision for validation tooling.

## Verification Selected For This Decision

This change modifies Closed-Loop process documentation only. The selected
verification is ledger validation and changed-file verification planning. App
XCTest is intentionally omitted because no app source or Xcode project behavior
changed.

## Limitation

This record improves project-local operating rules. It cannot force external
Codex UI panels or already-running agents from earlier sessions to update their
state; new tasks must be briefed with the bootstrap facts.
