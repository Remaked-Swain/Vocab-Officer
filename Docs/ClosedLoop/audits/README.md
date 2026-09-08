# Closed-Loop Audit Artifacts

Durable runs store the concise, read-only Auditor decision here as
`RUN-*-audit.md`. Ordinary transient audits remain temporary and are not
committed.

An approval records the reviewed worktree SHA-256 in the pipeline state.
Completed durable chain state is retained locally under
`.git/closed-loop-pipeline/completed/`.
