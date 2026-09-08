# Closed-Loop Operating Policy

This directory is durable, scoped project memory. The active agent contract
starts at `AGENTS.md`; this document defines the audited workflow and record
lifecycle.

## When To Use It

The main agent performs ordinary work directly. Use one Auditor subagent after
the implementation when a change affects code, persistence, sync, security,
data safety, release output, or this harness.

Do not spawn an Auditor for simple questions, read-only inspection, status
reports, or command-only operations. Never spawn role-playing Director,
Executor, Monitor, or Recorder agents. The only allowed subagent is one
read-only Auditor.

Use:

- `transient` evidence for normal code changes. It enforces review while
  avoiding permanent records for routine implementation details.
- `durable` evidence for architecture, business rules, migration, deletion,
  security, data-loss, or harness decisions needed by future sessions.

## Bootstrap

Before editing or starting a run, the main agent must establish:

1. canonical root: `/Users/swainyun/Desktop/Project/Vocab`
2. active sandbox permissions
3. current Git status and unrelated changes to preserve
4. intended changed-file scope
5. focused verification selected by `script/verify_changed.sh --plan`

Read `INDEX.md` first. Load only records whose scope intersects the task.
`index.json` is for tooling and does not need to enter conversational context.

## Enforced Flow

`script/closed_loop_pipeline.sh` enforces:

`Main implementation -> Auditor review -> Main close`

On rejection it enforces:

`Main implementation -> Auditor reject -> same Main rework -> same Auditor review`

The main agent may edit code and documents. The Auditor is read-only and
reviews the actual diff, relevant tests, regressions, data-loss risk, and
requirement coverage. It must not implement fixes.

Each role identity is bound once per run. A rejection reuses both identities;
replacement identities are rejected. Rejection count is retained only for
diagnostics and never terminates the loop. Main and Auditor identities must be
different. The loop continues until approval; a genuine blocker is reported to
the user instead of being converted into an arbitrary retry-limit failure.
Every handoff requires the predecessor artifact SHA-256, and a changed,
missing, empty, skipped, stale, or out-of-order artifact blocks progress.
Run mutation is locked and state is written with atomic rename.

Typical transient run:

```bash
./script/closed_loop_pipeline.sh start RUN-ID transient
./script/closed_loop_pipeline.sh register-role RUN-ID Main codex-main GENESIS
./script/closed_loop_pipeline.sh submit RUN-ID Main codex-main /tmp/main-report.md
./script/closed_loop_pipeline.sh register-role RUN-ID Auditor auditor-1 <main-sha256>
./script/closed_loop_pipeline.sh review RUN-ID Auditor auditor-1 approve /tmp/audit.md
./script/closed_loop_pipeline.sh register-role RUN-ID Main codex-main <audit-sha256>
./script/closed_loop_pipeline.sh close RUN-ID Main codex-main /tmp/close.md
```

A durable run uses `durable` at start and requires every submitted Main
artifact to be one canonical `Docs/ClosedLoop/records/CL-*.md` file. Close
validates that the Auditor-approved record is unchanged and registered in both
indexes. Its approval artifact must be a canonical
`Docs/ClosedLoop/audits/RUN-*-audit.md` file. Approval hashes the complete Git
worktree, and close fails after any tracked or untracked repository change.
The completed registration and artifact hash chain remains locally under
`.git/closed-loop-pipeline/completed/`. This makes the audit authoritative
without a separate Recorder agent.

## Audit Contract

The main report must contain:

- request and accepted interpretation
- changed paths and notable design choices
- exact verification results and omissions
- known limitations or pending user approval

The Auditor must return one of:

- `approve`: no blocking correctness, regression, data-safety, test, or
  contract finding remains
- `reject`: actionable findings with file and line references

For Swift changes, both roles must apply `Docs/SwiftStyleGuide.md`. The
automated checker owns objective bans; the Auditor owns contextual judgement
such as early-exit structure, naming, concurrency, architecture, and test
quality.

An approval is not permission to alter the reviewed artifact or any other
repository file. Any post-review change requires another Main submission and
Auditor review.

## Durable Records

Decision records use `active`, `superseded`, `archived`, or `deleted`.
Each record includes its ID, date, scope, accepted decision, evidence,
limitations, retention rule, and supersession metadata.

The record validator rejects:

- duplicate IDs or missing required metadata
- status drift between Markdown and JSON
- broken or non-reciprocal supersession links
- missing files and unindexed `records/CL-*.md` files

Only decisions with future value receive durable records. Raw build logs,
transient agent conversation, routine diffs, DerivedData, and result bundles
must not be persisted.

## Retention

| State | Rule |
| --- | --- |
| `active` | Retain and index while behavior remains active. |
| `superseded` | Retain at least 90 days after replacement. |
| `archived` | Retain only while it explains active behavior, migration, security, deletion, or acceptance evidence. |
| `deleted` | Only duplicates, abandoned drafts without implementation effect, or expired operational noise; retain an index tombstone. |

Data deletion, migration, security, backup compatibility, grading, and
acceptance records remain protected while the app depends on them. Use
`script/closed_loop_records.sh can-delete` before reviewed deletion.

## Verification

`script/verify_changed.sh` is the executable impact-to-test map. Use changed
paths to select the smallest meaningful suite. Full tests remain required for
broad shared contracts, persistence/schema changes, release acceptance, or an
Auditor request.

For harness changes, run:

```bash
bash -n script/closed_loop_pipeline.sh
./script/closed_loop_pipeline.sh --self-test
./script/closed_loop_records.sh --self-test
./script/closed_loop_records.sh validate
./script/verify_changed.sh --self-test
./script/swift_style_check.sh --self-test
./script/swift_style_check.sh
```

This policy supersedes the four-role lifecycle in CL-0012, CL-0015, and
CL-0018. Their historical evidence remains available for rollback reasoning.
