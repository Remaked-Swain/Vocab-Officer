# Closed-Loop Operating Policy

This directory is the durable memory for the four-agent Closed-Loop workflow.
Its contents remain in source control after Director, Executor, Monitor and
Recorder agents have been terminated.

## Start Of A Loop

1. Spawn the four required agents.
2. An agent reads `INDEX.md` only. Tooling may read `index.json` to validate
   ledger integrity without loading full decision text.
3. Load individual records or run reports only when their `Scope` intersects the requested
   work or when they are listed as a dependency of a new decision.
4. Have the Recorder add or update a record before the loop is closed.

This keeps prior decisions available without loading unrelated history on every
task.

## Record Contract

Decision records use `active`, `superseded`, `archived`, or `deleted`. Run
records use `in-review`, `completed`, `archived`, or `deleted`.

Each record must contain:

- record ID and applicable status
- date, affected scope and agents involved
- accepted decision and relevant constraints
- verification evidence and known limitations
- superseding record ID when applicable
- archive review date

`INDEX.md` is the only mandatory decision-history read at task start.
`index.json` is the machine-readable source for integrity tooling, not
mandatory conversational context. Records are immutable once superseded
except for archive metadata or factual correction.

## Retention And Deletion

| State | Storage | Rule |
| --- | --- | --- |
| `active` | `records/` | Always retained and indexed. |
| `superseded` | `records/` | Retain for 90 days after replacement so rollback reasoning remains available. |
| `archived` | `archive/YYYY/` | Retain while it explains active behavior, data migration, security, deletion or acceptance evidence. |
| `deleted` | none | Allowed only for duplicates, abandoned drafts without implementation effect, or expired operational noise. Record the deletion in `INDEX.md`. |

Records that establish data deletion, backup compatibility, grading/mastery
semantics, or acceptance evidence must not be deleted while the application
uses that behavior. An archive review is a deliberate repository change, not
an automatic cleanup job.

To archive a record, move it to `archive/<year>/`, update its index row and
identify the superseding record in the same reviewed change. To delete an
eligible record, remove it and keep an index tombstone containing its ID,
deletion date and deletion reason. Generated build directories and raw test
result bundles remain excluded from Git; records store only compact evidence
paths and outcomes.

Use `script/closed_loop_records.sh validate` before closing a loop, and
`script/closed_loop_records.sh can-delete <ID> <reason>` before any deletion. Deletion
still requires Director and Monitor approval in a new recorded change.

## Verification Selection

Run `script/verify_changed.sh` with the files changed by the current loop.
This executable is the single source of truth for impact-to-verification
mapping:

```bash
./script/verify_changed.sh Docs/ClosedLoop/README.md script/verify_changed.sh
./script/verify_changed.sh Vocab/Domain/StudyPolicies.swift
```

The script maps affected ownership boundaries to the smallest meaningful
verification. Use `--plan` to inspect its selection without executing it. A
full test suite remains required for broad cross-layer changes, Xcode project
changes, persistence or backup schema changes, release acceptance, or when
the Monitor requests it. Every decision record must state what was run and why
any broader validation was omitted.

When no explicit changed-file list is supplied and the repository has no
baseline commit, the script selects the full XCTest fallback. During the
current process-only change, pass the exact changed paths so the reason for
omitting application tests is explicit and recordable.
