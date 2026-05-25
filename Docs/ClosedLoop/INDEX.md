# Closed-Loop Decision Index

Read this file at the start of a new Closed-Loop task. Read a linked record
only when its scope applies to the current change.

| ID | Status | Date | Scope | Record | Review |
| --- | --- | --- | --- | --- | --- |
| CL-0001 | active | 2026-05-25 | vocabulary rules, persistence, backup, UI foundation | [Vocab MVP implementation](records/CL-0001-vocab-mvp-implementation.md) | retain while app exists |
| CL-0002 | active | 2026-05-25 | Closed-Loop operations, record retention, targeted verification | [Durable records and selective verification](records/CL-0002-durable-records-and-selective-verification.md) | 2026-08-23 |
| RUN-20260525-CL0002 | completed | 2026-05-25 | workflow implementation evidence | [Run record](runs/RUN-20260525-CL0002.md) | completed after Monitor and Director approval |

## Load Rules

- Any change to vocabulary behavior, backup/restore, deletion or user-facing
  testing must load `CL-0001`.
- Any future Closed-Loop task must apply `CL-0002`; reading its full record is
  required only when changing workflow, retention or verification rules.
- Superseded or archived records are read only when investigating regression,
  migration history or a stated dependency.
- `index.json` is the machine-readable companion for validation tooling only.
- `script/verify_changed.sh` is the executable source of truth for test
  impact selection; changing it requires its plan-fixture verification.
