---
paths:
  - "**/*.swift"
---

# Swift Conventions

Objective bans live in `.claude/lint/swift.rules` (run by
`.claude/lint/swift_lint.sh` after every `.swift` edit). The Auditor owns the
contextual rules below.

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

- Modern Swift Concurrency only. No `DispatchQueue`, `DispatchGroup`,
  `DispatchSemaphore`, `NSLock`/unfair locks (lint `legacy-concurrency`, no
  baseline); isolate mutable state in actors.
- Replacements: shared state reached asynchronously → an actor (or the
  owning `@MainActor` type); a short critical section that must stay
  synchronous → `Mutex` (Synchronization); callback or delegate APIs → an
  `async` wrapper or `AsyncStream`, preferring the OS's own async API
  (e.g. `NWPathMonitor` is an `AsyncSequence`). A timeout over cooperative
  work races in a task group; one that must return while uncooperative
  work is still running races through a first-value `AsyncStream`
  (`VocabAsyncDeadline`), never a lock-guarded continuation. No
  `@unchecked Sendable`, `Thread.isMainThread` checks, `ObservableObject`
  or `Task.sleep(nanoseconds:)`; use isolation, `@Observable` and
  `Duration`.
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
