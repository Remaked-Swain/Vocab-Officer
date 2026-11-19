# CL-0038: Open Context Discovery And Durable Routing

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-11-19 (Asia/Seoul) |
| Scope | policy discovery, fail-open routing, semantic recall, conflict handling, cross-session continuity |
| Agents | Codex main agent, one read-only Auditor |
| Supersedes | CL-0037 |
| Archive review | retain while Codex workflow uses this harness |

## Problem

CL-0037 reduced initial context but incorrectly made router output an exclusive
document boundary. Path-only and compound work could silently omit useful
architecture and product decisions. Its validation proved internal manifest
consistency rather than semantic recall, and its audit reused implementation-
authored fixtures as the primary oracle.

## Decision

- Router output is a known minimum and discovery aid, never an allowlist.
- Separate known-required, likely relevant, conditional and warning output.
- Fail open to the compact catalog, direct repository inspection and the full
  index whenever routing is unsuccessful or uncertain.
- Combine structural paths, semantic tags and typed `requires`/`recommends`
  edges. Path-only application work always loads Architecture and Verification.
- Re-run discovery after code inspection and against the final diff.
- Preserve provenance for every routed document and surface unresolved
  conflicts instead of choosing one silently.
- Validate representative compound scenarios and require the Auditor to add
  independent false-negative cases beyond implementation fixtures.
- A real counterexample withdraws approval for its affected scope and returns
  this decision to `in-review` until re-audit.
- Version `AGENTS.md`, the registry, schema, catalog, scenarios and this record
  so later sessions and agents inherit the same contract without conversation
  history.

## Acceptance Gate

- All golden and independent adversarial scenarios retain every expected
  required document.
- Path-only shared code, unknown tags, uncovered paths and router failure emit
  visible fail-open guidance.
- Compound tasks produce the union of requirements without suppressing any
  required source.
- Superseded records cannot become required except through an explicit
  historical condition.
- Only likely-relevant ordering may be optimized for context cost.
- Normal-entry use begins only after the read-only Auditor approves the actual
  diff and independently constructed counterexamples.

## Implementation Evidence

- `Docs/Rules/policy-registry.json` replaces the exclusive route manifest with
  21 structural and semantic rules, typed edges, provenance and explicit
  uncertainty fallbacks.
- `Docs/Rules/routing-scenarios.json` covers every registered task tag plus
  path-only shared code, path-only mastery presentation and an uncovered
  repository path. Recommended-edge recursion is asserted separately from
  required-document recall.
- Registry validation rejects missing routed sources, inactive required or
  recommended decisions, dependency cycles, untested task tags and any active
  permanent decision that has no discovery route.
- The executable JSON Schema validator applies nested types, required fields,
  enums, uniqueness and unknown-property rejection. Its negative fixtures
  cover malformed conditions, duplicate documents and invalid workflow values.
- Active permanent decisions whose sufficiently specific `affectedPaths`
  intersect an application path are added as likely relevant with ledger
  provenance; broad one-component roots are excluded to bound noise.
- `Docs/Verification.md` was reconciled with the active setless vocabulary
  decision so the router does not knowingly return contradictory acceptance
  criteria.

## Verification Evidence

- `script/verify_changed.sh` selected only shell, record and routing harness
  checks; no unit test, platform build or reinstall was selected.
- The routing self-test passed 18 semantic scenarios, unknown-tag fail-open
  behavior, recursive recommended dependency retention and path-only workflow
  requirements for both routing support scripts.
- The Closed-Loop pipeline and record self-tests passed, and the 42-record
  durable index validated.
- Independent counterexamples approved activation readiness. The resulting
  active-state worktree remains subject to final hash-bound Auditor approval.

## Context Cost Proxy

`script/measure_context_routing.sh` compares selected UTF-8 source bytes with
the 46-document policy universe. This is reproducible but is not presented as
tokenizer-exact accounting.

| Case | Selected documents | Selected bytes | Universe bytes | Ratio |
| --- | ---: | ---: | ---: | ---: |
| path-only mastery | 21 | 103,920 | 210,872 | 49.3% |
| compound study | 24 | 95,079 | 210,872 | 45.1% |
| CloudKit | 19 | 100,597 | 210,872 | 47.7% |
| harness | 8 | 31,046 | 210,872 | 14.7% |

The benchmark includes all required and likely-relevant documents; it never
removes a required source to satisfy a budget.

## Limitation

No finite scenario suite proves semantic completeness. The design therefore
keeps direct inspection open, makes uncertainty visible and treats future
counterexamples as approval-revocation events rather than exceptional noise.
