# Closed-Loop Operating Policy

This directory is the durable memory for the four-role Closed-Loop workflow.
Its contents remain in source control after Director, Executor, Monitor and
Recorder work has ended. Roles must run as just-in-time sequential handoffs;
parallel independent role execution is prohibited.

## Start Of A Loop

Closed-Loop is not the default workflow. The Director decides whether to use
it for the current task and records both the decision and reason in the
Director artifact. Use it only when the change needs durable decision evidence,
ordered multi-role review, auditability, or explicit user instruction. Do not
use it for simple inspection, routine single-agent edits, command-only
questions, or changes whose risk and audit value do not justify the extra
handoffs.

1. Confirm the session bootstrap facts before spawning or editing:
   - canonical project root: `/Users/swainyun/Desktop/Project/Vocab`
   - active sandbox profile and whether project access requires escalated
     commands
   - current Git status and unrelated dirty files that must be preserved
   - exact changed-file scope expected for the task
   - Swift/Xcode verification command selected by `script/verify_changed.sh`
2. Start only the Director. Do not pre-spawn or pre-register Executor, Monitor
   or Recorder work.
3. Create the run, register the active Director, and submit its artifact.
   Registration of a successor requires the predecessor artifact SHA-256 shown
   as the pipeline handoff token.
4. Give each role the bootstrap facts above when its turn begins. Agents must
   not infer the project root from the transient Codex thread `cwd` when it
   differs from the canonical root.
5. An agent reads `INDEX.md` only. Tooling may read `index.json` to validate
   ledger integrity without loading full decision text.
6. Load individual records or run reports only when their `Scope` intersects
   the requested work or when they are listed as a dependency of a new
   decision.
7. The orchestrator must wait for the current role artifact to be accepted
   before activating the next role. Spawn each role at most once per run, when
   that role first becomes eligible, then retain its agent session idle and
   reuse it for every later turn in the same run. A handoff changes the active
   role; it does not close the predecessor session.
8. Advance only in this order:
   `Director analysis -> Executor change -> Monitor review -> Recorder record
   -> Director close`.
   A Monitor rejection reactivates the original Executor ID and execution
   context; it must not spawn or register a replacement Executor. At most three
   rejections are allowed. Approval advances to Recorder.
9. Do not create Executor, Monitor or Recorder concurrently. Create each role
   only after the previous stage is accepted and the pipeline opens the next
   stage. The Recorder is created only after Monitor approval.
10. During a Closed-Loop run, the Codex main agent must not directly change
    code or documentation. It only orchestrates role order, handoff tokens,
    sandbox state, token budget and verification visibility. File changes are
    performed by the active Executor, and records are performed by the Recorder
    after approval.
11. Have the Recorder add or update a valid indexed decision record before
    Director close.
12. Keep a run-local `role -> agent ID` map. Use the existing agent ID and send
    only the new artifact token, review delta and required bootstrap changes on
    reactivation. `resume_agent` is recovery-only; do not close and resume a
    healthy role merely to perform a handoff.
13. Close retained role sessions exactly once, after Monitor approval,
    Recorder persistence and validated Director close. Earlier replacement is
    allowed only for an unrecoverable agent failure, explicit cancellation or
    a hard concurrency-capacity requirement, and its reason must be included
    in the run evidence.

## Sequential Handoff Enforcement

`script/closed_loop_pipeline.sh` is the executable state machine for agent
handoffs. `start` opens only the Director stage and registers no identity.
Every stage requires a separate just-in-time `register-role` call. The first
registration binds the role to one run-scoped agent session; later
registrations activate that retained identity without respawning it. The call
accepts only the current role and the exact predecessor artifact SHA-256 as its
handoff token, so future-role registration, duplicate active registration and
stale or invented tokens fail. Registration also re-hashes the predecessor
artifact file immediately and requires its current hash, stored hash and token
to match; post-submission artifact mutation therefore blocks the successor.

Every transition requires a non-empty artifact file. State stores ordered role
registrations with timestamps and the artifact chain's previous hash, content
hash and cumulative chain hash before opening the next stage. The script also
rejects an unexpected role, a skipped stage, an empty or missing artifact, a
replacement Executor after rejection, and a fourth rejection.

Each run has a concurrent mutation lock. State is written through a same-folder
temporary file and atomic rename. A Recorder artifact must be a direct,
canonical `Docs/ClosedLoop/records/CL-*.md` path. Before Director close, its
record row in `INDEX.md` must link the exact `records/CL-*.md` path,
`index.json` must contain the exact project-relative path, and
`script/closed_loop_records.sh validate` must pass. Successful close removes
the run's temporary state.
Use `CLOSED_LOOP_STATE_DIR` only to isolate tests or an explicitly managed
runtime; normal state is under `.git/closed-loop-pipeline`.

Typical approval commands:

```bash
./script/closed_loop_pipeline.sh start RUN-ID
./script/closed_loop_pipeline.sh register-role RUN-ID Director director-1 GENESIS
./script/closed_loop_pipeline.sh submit RUN-ID Director director-1 director.md
./script/closed_loop_pipeline.sh register-role RUN-ID Executor executor-1 <director-sha256>
./script/closed_loop_pipeline.sh submit RUN-ID Executor executor-1 executor.md
./script/closed_loop_pipeline.sh register-role RUN-ID Monitor monitor-1 <executor-sha256>
./script/closed_loop_pipeline.sh review RUN-ID Monitor monitor-1 approve monitor.md
./script/closed_loop_pipeline.sh register-role RUN-ID Recorder recorder-1 <monitor-sha256>
./script/closed_loop_pipeline.sh submit RUN-ID Recorder recorder-1 \
  Docs/ClosedLoop/records/CL-NNNN-record.md
./script/closed_loop_pipeline.sh register-role RUN-ID Director director-1 <record-sha256>
./script/closed_loop_pipeline.sh close RUN-ID Director director-1 close.md
```

Typical rejection commands keep the same Executor identity:

```bash
./script/closed_loop_pipeline.sh review RUN-ID Monitor monitor-1 reject monitor.md
./script/closed_loop_pipeline.sh register-role RUN-ID Executor executor-1 <monitor-sha256>
./script/closed_loop_pipeline.sh submit RUN-ID Executor executor-1 executor-rework.md
./script/closed_loop_pipeline.sh register-role RUN-ID Monitor monitor-1 <executor-rework-sha256>
./script/closed_loop_pipeline.sh review RUN-ID Monitor monitor-1 approve monitor-approval.md
```

The shell cannot prevent Codex or another external orchestrator from spawning
or closing agents outside this API. The orchestrator is therefore responsible
for spawning a role only when the pipeline first opens it, retaining the
run-scoped role-to-agent mapping, keeping inactive roles idle, and closing all
retained sessions only after validated loop closure. Pipeline registration and
hash-chain state provide enforcement at the repository boundary and audit
evidence for identity replacement attempted through the API.

`CL-0018` partially replaces `CL-0012` only for agent-session lifecycle:
sequential activation remains mandatory, but healthy sessions are retained and
reused until the run closes. This sequential enforcement partially replaces
the earlier general multi-agent startup guidance in `CL-0002` and `CL-0007`.
`CL-0015` further
replaces the previous default-use rule: Closed-Loop is opt-in per Director
decision, with recorded use or non-use reasoning. Their retention, bootstrap,
project-root and verification rules remain active.

This keeps prior decisions available without loading unrelated history on every
task.

## Tooling Discipline

Vocab is a macOS SwiftUI and SwiftData application. Default implementation and
verification work should therefore use Swift, XCTest, Xcode build settings and
project-local scripts. Python may be used for repository tooling, fixture
generation, data inspection or one-off analysis, but not as the default way to
rewrite Swift source. Manual source edits should use patches, and broad
mechanical rewrites should be followed by Swift/Xcode compilation or tests.

For app changes, prefer this order:

1. Inspect with `rg`, `sed`, `xcodebuild -list` and project-local scripts.
2. Edit Swift and project files directly.
3. Verify with focused XCTest or `script/verify_changed.sh`.
4. Use `script/build_and_run.sh --install-verify` for release-install
   acceptance when the user-facing app must be updated.

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
