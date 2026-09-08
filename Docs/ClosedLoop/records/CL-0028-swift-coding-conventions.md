# CL-0028: Swift Coding Conventions

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-09-04 (Asia/Seoul) |
| Scope | Swift coding conventions, automated style checks, and Auditor review |
| Agents | Codex main agent, one read-only Auditor |
| References | CL-0002, CL-0007, CL-0025, CL-0027 |
| Archive review | retain while Swift code is maintained in this repository |

## Problem

The repository had architecture and verification policies but no single Swift
coding-convention contract. Preferences such as using `guard` for early exits
and `for-in` for imperative iteration therefore depended on each session's
memory and could not be checked consistently.

## Request And Interpretation

The user asked whether a documented coding convention could become part of the
harness and whether both apps could be reinstalled. The accepted implementation
adds an enforceable repository contract rather than attempting an indiscriminate
format rewrite. Reinstallation is a release operation performed after approval,
using the existing bundle identifiers without uninstalling or deleting either
platform's SwiftData container.

## Decision

- `Docs/SwiftStyleGuide.md` is the repository-wide Swift convention.
- Every agent must load it before editing or reviewing Swift code.
- Objective rules are enforced by `script/swift_style_check.sh` and selected
  automatically by `script/verify_changed.sh` for Swift changes.
- Contextual rules are reviewed by the single read-only Auditor. In particular,
  `guard` versus `if` cannot be reliably decided by text matching because many
  valid UI and business branches use `if` without representing an early exit.
- The checker uses the repository-standard `rg` executable and fails closed if
  it is unavailable or returns an execution error. It checks universally
  applicable rules in production and tests; production-only safety bans avoid
  rejecting intentional failure fixtures.
- Convention failures block Closed-Loop approval and release acceptance.

## Evidence

- Changed paths for this decision are `AGENTS.md`, `Docs/SwiftStyleGuide.md`,
  `Docs/Verification.md`, `Docs/ClosedLoop/README.md`, both Closed-Loop indexes,
  this record, `script/swift_style_check.sh`, `script/verify_changed.sh`, and
  four pre-existing production violations in `Vocab/App/` and
  `Vocab/Presentation/`.
- The style checker includes isolated failure fixtures for every enforced rule,
  a passing `fatalError` exception fixture, and missing-tool and scanner-error
  fail-closed fixtures; its self-test and full repository scan passed. The
  scanner command cannot be overridden by normal execution environment.
- Verification-selection self-tests prove that Swift changes select the style
  checker and convention/harness changes select all relevant harness checks.
- Shell syntax, Closed-Loop pipeline self-tests, record-validator self-tests,
  index validation for 32 records, and `git diff --check` passed.
- The full macOS XCTest suite completed with `** TEST SUCCEEDED **`; CloudKit
  integration and large-fixture performance cases that require explicit runtime
  conditions remained skipped by their existing test gates.
- Existing `try!` and `DispatchQueue.main.async` violations were removed. The
  sole `fatalError` remains only at the irrecoverable point where no model
  container can be created to render recovery UI, with the required marker and
  rationale.

## Limitations

Semantic style choices, API clarity, architecture boundaries, and test quality
still require human or Auditor judgement. Expanding regex checks without a low
false-positive rate is prohibited because noisy enforcement weakens trust in
the harness. Physical-device installation and launch are release operations
performed after this decision is approved and may still depend on device trust,
unlock state, and provisioning availability.
