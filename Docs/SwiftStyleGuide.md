# Swift Coding Conventions

This guide is the repository-wide convention for production Swift, tests, and
review. It complements the architecture and product decisions in
`Docs/ClosedLoop/INDEX.md`.

## Control Flow

- Use `guard` for preconditions, required optional values, invalid-state exits,
  and early returns. Keep the successful path at the lowest indentation level.
- Use `if` when both branches are meaningful, when rendering conditional UI,
  or when a value is conditionally transformed without leaving the scope.
- Do not replace a clear `if` with `guard` mechanically. The choice must express
  whether the condition is an exit condition or a business decision.
- Prefer `switch` for exhaustive enum handling and three or more mutually
  exclusive cases.

## Iteration

- Use `for-in` for side effects, mutation, throwing or asynchronous work, and
  loops that may use `break` or `continue`.
- Use `map`, `compactMap`, `filter`, and `reduce` only for value transformation.
- Do not use `forEach`; it obscures control flow and cannot use normal loop
  control statements.
- Avoid repeated linear scans in rendering and hot paths. Build keyed lookups
  once when the same collection is queried repeatedly.

## Naming And API Shape

- Follow the Swift API Design Guidelines: types use `UpperCamelCase`; methods,
  properties, variables, and enum cases use `lowerCamelCase`.
- Name booleans as assertions such as `isReady`, `hasChanges`, or `canSubmit`.
- Prefer names that describe domain intent over storage or UI implementation.
- Avoid unexplained abbreviations and redundant type words.
- Keep functions focused. Extract a helper when it gives a business rule a
  name, removes meaningful duplication, or separates effects from decisions.

## Safety And Errors

- Production code must not use `try!`, `as!`, or `preconditionFailure`.
  `fatalError` is permitted only when application bootstrap cannot construct
  even an error UI and no recovery value exists. That line must include
  `swift-style: allow(fatalError)` and a rationale, and the Auditor must approve
  the invariant. Represent recoverable failures and surface actionable,
  natural-language messages at the UI boundary.
- Prefer typed errors and explicit fallback behavior over silent failure.
- Never delete, replace, migrate, or rebuild a SwiftData store as an incidental
  response to a read, sync, launch, or schema error.

## Concurrency And UI

- Keep UI state on `@MainActor`; move network, CloudKit, OCR, serialization,
  and large collection work off the main actor.
- Use structured concurrency and cancellation. Do not introduce
  `DispatchQueue.main.async` as a substitute for actor isolation.
- Avoid unbounded work from lifecycle events. Coalesce duplicate requests and
  make foreground synchronization incremental and non-blocking.
- SwiftUI views should render prepared state rather than repeatedly scanning or
  sorting the full model graph in `body`.

## Architecture

- Domain code must not depend on SwiftUI, SwiftData, CloudKit, or platform UI.
- Application code coordinates use cases; infrastructure and data code own
  persistence and external services; presentation code owns interaction state.
- Preserve the single source of truth for a headword. Set membership and
  progress reference the canonical word instead of duplicating it.
- Keep macOS and iOS business rules shared. Platform-specific UI may differ to
  match each platform's interaction model.

## Formatting And Documentation

- Use four-space indentation, no trailing whitespace, and one final newline.
- Wrap long declarations and calls where argument structure becomes clearer.
- Add comments for rationale, invariants, and non-obvious constraints, not for
  line-by-line narration.
- Public-facing text must be readable Korean or intentional English, not raw
  error codes or implementation diagnostics.

## Tests

- Name tests after behavior and outcome. Arrange inputs so a failure identifies
  the broken rule without reading the implementation.
- Assert externally visible state and meaningful invariants, not private steps.
- Cover success, boundary, rejection, correction, and data-preservation paths
  in proportion to risk. Do not weaken assertions merely to make a test pass.
- Run the smallest relevant suite selected by `script/verify_changed.sh`.
  Shared schema, persistence, synchronization, and release changes require the
  broader suite selected by that script.

## Enforcement

Run `script/swift_style_check.sh` for every Swift change. It checks universally
applicable iteration and main-actor rules in production and tests, and applies
runtime-safety bans to production targets where test fixtures may intentionally
exercise failures. It fails closed if its repository-standard `rg` search tool
is unavailable or errors. The Auditor must review contextual rules, especially
`guard` versus `if`, loop choice, naming, actor boundaries, architecture
dependencies, and test credibility.
