# Closed-Loop Decision Index

Read this file at the start of a new Closed-Loop task. Read a linked record
only when its scope applies to the current change.

| ID | Status | Date | Scope | Record | Review |
| --- | --- | --- | --- | --- | --- |
| CL-0001 | active | 2026-05-25 | vocabulary rules, persistence, backup, UI foundation | [Vocab MVP implementation](records/CL-0001-vocab-mvp-implementation.md) | retain while app exists |
| CL-0002 | active | 2026-05-25 | Closed-Loop operations, record retention, targeted verification | [Durable records and selective verification](records/CL-0002-durable-records-and-selective-verification.md) | 2026-08-23 |
| RUN-20260525-CL0002 | completed | 2026-05-25 | workflow implementation evidence | [Run record](runs/RUN-20260525-CL0002.md) | completed after Monitor and Director approval |
| CL-0003 | active | 2026-05-26 | local data entry, JSON/managed-backup removal | [Local-only intake without JSON backup features](records/CL-0003-local-intake-without-json-backup.md) | retain while app exists |
| RUN-20260526-CL0003 | completed | 2026-05-26 | feature removal and 2026-05-25 intake execution | [Run record](runs/RUN-20260526-CL0003.md) | completed after Monitor, Director and Recorder approval |
| CL-0004 | active | 2026-05-26 | in-app paste intake, accessibility and repository publishing hygiene | [In-app paste intake and publish hygiene](records/CL-0004-in-app-paste-and-publish-hygiene.md) | retain while feature or public repository exists |
| RUN-20260526-CL0004 | completed | 2026-05-26 | accessible paste intake and repository hygiene execution | [Run record](runs/RUN-20260526-CL0004.md) | completed after Director, Monitor and Recorder approval |

## Load Rules

- Any change to vocabulary behavior, backup/restore, deletion or user-facing
  testing must load `CL-0001`.
- JSON, managed-backup, deletion or operator intake work must also load
  `CL-0003`; it overrides the removed backup portions of `CL-0001`.
- Daily intake UI, paste-format handling or public repository hygiene work
  must load `CL-0004`.
- Any future Closed-Loop task must apply `CL-0002`; reading its full record is
  required only when changing workflow, retention or verification rules.
- Superseded or archived records are read only when investigating regression,
  migration history or a stated dependency.
- `index.json` is the machine-readable companion for validation tooling only.
- `script/verify_changed.sh` is the executable source of truth for test
  impact selection; changing it requires its plan-fixture verification.
