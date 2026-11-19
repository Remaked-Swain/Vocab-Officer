# Policy Discovery Contract

The context router is a discovery aid, never a document-access allowlist.

## Output Meaning

- **Known-required minimum** is the smallest set known to be mandatory from the
  current intent, task tags and paths. It is not a claim of semantic
  completeness.
- **Likely relevant** documents should be inspected when they can clarify the
  current scope. Context budgets may reorder this tier but must not remove the
  known-required minimum.
- **Conditional** entries state the evidence that makes another document
  required.
- **Warnings** identify uncertainty. Agents must resolve or explicitly retain
  each warning before completion.

Agents may always inspect additional repository documents. They must do so
when dependencies, conflicts, ambiguity or changed scope emerge.

## Discovery Loop

1. Route the initial request and planned paths.
2. Inspect code and the known-required documents.
3. Route again when domains or paths are discovered or changed.
4. Before completion, route the actual diff and reconcile warnings with the
   documents used for implementation and review.

## Fail Open

If the router, registry or schema is missing, malformed, outdated, ambiguous
or unsuccessful, do not continue with a narrow context. Load `AGENTS.md`, this
contract and `CATALOG.md`, inspect the repository directly, and consult the
full Closed-Loop index when uncertainty remains.

## Edges And History

`requires` promotes the target rule's required documents into the known-
required minimum. `recommends` adds them to likely relevant. Historical or
superseded records appear only under an explicit conditional route.

## Conflicts

Instruction precedence, active status and explicit supersession resolve only
unambiguous conflicts. Otherwise the router must warn and the Main must stop
for a product decision instead of selecting a convenient rule.

## Counterexamples And Approval

A real false negative withdraws approval for the affected routing scope. The
decision returns to `in-review`, the counterexample becomes a permanent
scenario, and normal-entry use resumes only after independent re-audit.
