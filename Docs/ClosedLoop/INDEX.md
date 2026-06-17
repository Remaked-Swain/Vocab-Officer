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
| CL-0005 | active | 2026-05-26 | selected-set testing, study cards, judgement transparency and local installation | [Study cards, selected-set testing and local installation](records/CL-0005-study-cards-selected-set-testing-and-installation.md) | retain while feature exists |
| RUN-20260526-CL0005 | completed | 2026-05-26 | defect repair, card study and installation evidence | [Run record](runs/RUN-20260526-CL0005.md) | completed after Director, Monitor and Recorder approval |
| CL-0006 | active | 2026-05-28 | English-to-Korean review priority decay and review eligibility | [English-to-Korean review decay](records/CL-0006-english-to-korean-review-decay.md) | retain while scheduler exists |
| CL-0007 | active | 2026-06-09 | session bootstrap, sandbox awareness and Swift/Xcode-first tooling | [Session bootstrap and tooling discipline](records/CL-0007-session-bootstrap-and-tooling-discipline.md) | retain while Codex workflow exists |
| CL-0008 | active | 2026-06-10 | loose-word test eligibility and fair presentation | [Loose word testing](records/CL-0008-loose-word-testing.md) | retain while loose-word intake and testing exist |
| CL-0009 | active | 2026-06-12 | review-mode previous-set re-exposure and 14+6 selection | [Previous-set review re-exposure](records/CL-0009-previous-set-review-reexposure.md) | retain while review-session selection exists |
| CL-0010 | active | 2026-06-17 | parenthesized-comma meaning tracking and correction | [Parenthesized-comma meaning tracking](records/CL-0010-parenthesized-comma-meaning-tracking.md) | retain while correction and meaning-tracking behavior exists |

## Load Rules

- Any change to vocabulary behavior, backup/restore, deletion or user-facing
  testing must load `CL-0001`.
- JSON, managed-backup, deletion or operator intake work must also load
  `CL-0003`; it overrides the removed backup portions of `CL-0001`.
- Daily intake UI, paste-format handling or public repository hygiene work
  must load `CL-0004`.
- Selected-set testing, test presentation safety, learning cards, judgement
  acknowledgement or local app installation work must load `CL-0005`.
- Parenthesized delimiter handling, confirmed core-meaning correction, or
  meaning trackability work must load `CL-0010`.
- Loose-word test eligibility or presentation work must load `CL-0008`.
- Review priority, failure checks, review session eligibility or scheduler work
  must load `CL-0006`.
- Review-session previous-set recurrence or its 14+6 selection rule must load
  `CL-0009`.
- Any future Closed-Loop task must apply `CL-0002`; reading its full record is
  required only when changing workflow, retention or verification rules.
- Any future task that uses agents or edits the app must apply `CL-0007`.
  Reading its full record is required when changing session bootstrap, sandbox
  handling, root-path handling or implementation tooling rules.
- Superseded or archived records are read only when investigating regression,
  migration history or a stated dependency.
- `index.json` is the machine-readable companion for validation tooling only.
- `script/verify_changed.sh` is the executable source of truth for test
  impact selection; changing it requires its plan-fixture verification.
