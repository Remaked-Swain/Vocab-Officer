---
paths:
  - "**/*.swift"
---

# Swift Conventions

Objective bans are enforced by `script/swift_style_check.sh` (hook-run after
every `.swift` edit). The Auditor owns the contextual rules below.

## Control Flow And Iteration

- `guard` for preconditions, required optionals, invalid-state exits and early
  returns; keep the success path least indented. `if` when both branches are
  meaningful, for conditional UI, or a scoped transform. Never convert
  mechanically. `switch` for enums and three or more exclusive cases.
- `for-in` for side effects, mutation, throwing/async work, `break`/`continue`.
  `map`/`compactMap`/`filter`/`reduce` only for value transformation. No
  `forEach`. Build keyed lookups instead of repeated linear scans in rendering
  and hot paths.

## Naming And API Shape

- Swift API Design Guidelines; booleans read as assertions (`isReady`,
  `canSubmit`); names describe domain intent; no unexplained abbreviations.
- Keep functions focused; extract a helper to name a business rule, remove
  real duplication or separate effects from decisions.

## Safety And Errors

- Production code: no `try!`, `as!`, `preconditionFailure`. `fatalError` only
  when bootstrap cannot build even an error UI, marked
  `swift-style: allow(fatalError)` with a rationale and Auditor approval.
- Typed errors and explicit fallbacks; user-facing messages are readable
  Korean or intentional English, never raw codes.
- Never delete, replace, migrate or rebuild a SwiftData store as an incidental
  response to a read, sync, launch or schema error.

## Concurrency And UI

- Modern Swift Concurrency only. No new `DispatchQueue`, `DispatchGroup`,
  `DispatchSemaphore`, `NSLock`/unfair locks; isolate mutable state in actors.
  Existing occurrences are a frozen backlog in
  `script/legacy-concurrency-allowlist.txt`, not precedent.
- UI state on `@MainActor`; network, CloudKit, OCR, serialization and large
  collection work off the main actor. Structured concurrency and cancellation.
- Lifecycle events never trigger unbounded work: coalesce, keep foreground
  sync incremental and non-blocking. Views render prepared state; no full
  model-graph scans or sorts in `body`.

## Formatting And Tests

- Four-space indent, no trailing whitespace, final newline. Comments explain
  rationale and invariants, not narration.
- Tests are named for behavior and outcome, assert visible state and
  invariants, cover success/boundary/rejection/correction/data-preservation
  in proportion to risk. Never weaken an assertion to pass.
