# CL-0037: Context Routing Harness

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-11-19 (Asia/Seoul) |
| Scope | agent bootstrap, rule routing, selective document loading, harness verification |
| Agents | Codex main agent, one read-only Auditor |
| Archive review | retain while Codex workflow uses this harness |

## Problem

The human Closed-Loop index mixes the complete decision ledger with natural-
language loading rules. Reading it at every task loads unrelated history, while
duplicated rules in agent, architecture and verification documents can drift.
Changed paths already select verification automatically, but no equivalent
executable source selects the documents that must enter agent context.

## Decision

- Keep `AGENTS.md` as the small always-loaded contract.
- Use `Docs/Rules/context-routes.json` as the machine-readable task-and-path to
  document map. It stores paths only and does not duplicate normative content.
- Run `script/route_context.sh` before loading detailed project documents. The
  main agent supplies `--intent inspect|change`, one or more task tags inferred
  from the request and the known changed paths, then reads only the returned
  documents. Inspection routes never require an Auditor or evidence run.
- Treat `Docs/ClosedLoop/INDEX.md` as the human ledger. Read it when adding or
  changing durable records, investigating history or when the router returns
  it explicitly; do not load it by default.
- Return Auditor and evidence requirements with the document route so workflow
  policy is decided from mutation intent and the same task/path input as
  context selection.
- Validate that every routed record exists, is indexed and remains active.
  The manifest also lists every active record carried over from the former load
  rules, so validation fails if one becomes unrouted without an explicit policy
  change. Route fixtures cover harness, CloudKit/Swift and read-only tasks.
- Keep `script/verify_changed.sh` authoritative for executable verification;
  the context router only reports the corresponding plan command.

## Evidence

- The router self-test proves a tagged read-only task loads its relevant
  decision without an Auditor, a Swift bootstrap change adds only bootstrap
  synchronization and style decisions, and a harness change selects durable
  evidence plus Auditor review.
- Manifest validation rejects duplicate route IDs, unknown tags, missing
  documents, unindexed records and inactive routed decisions.
- Closed-Loop ledger validation keeps the decision record and both indexes in
  sync without requiring the full ledger in normal agent context.

## Implementation Scope

- Added `Docs/Rules/context-routes.json` and `script/route_context.sh`.
- Changed `AGENTS.md` and the Closed-Loop bootstrap policy to route by intent
  before loading detailed documents.
- Replaced the natural-language loading section in `INDEX.md` with a pointer
  to the executable router while preserving the decision ledger.
- Extended `script/verify_changed.sh` so route-manifest changes select shell,
  router, pipeline and ledger verification without application XCTest.
- Added explicit inspect/change intent, narrow CloudKit routes, active-rule
  coverage validation, a frozen legacy-concurrency inventory and a `--final`
  boundary that defers full builds during implementation.

## Verification Selected For This Decision

Harness verification passed shell syntax, the verification-plan self-test, the
context-router self-test and validation, the Closed-Loop pipeline self-test,
the record-validator self-test and ledger validation (`41` indexed records).
Swift style and allowlist self-tests passed. Two focused multi-batch deletion
tests passed. The four unrelated LearningCoordinator failures reproduce at the
pre-change baseline `c6f67b3` with the same assertions; they are documented as
pre-existing rather than attributed to the three prepared sync commits. No
full platform build or reinstall was run.

## Limitations

Task tags are selected by the main agent because repository scripts cannot
reliably infer semantic intent from a natural-language request. Changed paths
still provide an independent structural fallback for Swift, application and
harness rules. Four mastery/meaning-tracking tests already fail at baseline
`c6f67b3`; this task proves non-regression but does not repair that separate
product-test defect.
