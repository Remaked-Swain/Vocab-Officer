# CL-0003: Local-Only Intake Without JSON Backup Features

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-05-26 (Asia/Seoul) |
| Scope | `Vocab/`, `VocabTests/`, `Tools/DailyIntakeImporter/`, user data operation |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | Retain while the application uses this data contract |

## Decision

The app no longer exposes JSON import, JSON export or app-managed JSON backup
and scrub behavior. Mastered deletion removes identifiable learning data from
the live local store only, while retaining non-identifying aggregate counts.

For user-requested bulk entry, a local operator tool may call the existing
atomic daily-intake use case with an explicit Seoul study date. It accepts a
tab-separated transient input file, not JSON, and is not exposed in the app UI.

This decision overrides only the JSON and managed-backup portions previously
recorded in `CL-0001`; the daily intake, testing, correction, priority and
mastery contracts remain active.

| Supersedes in part | `CL-0001` |
| Superseded scope | JSON import/export and app-managed backup creation, restore and scrub only |
| Remaining `CL-0001` scope | Intake, testing, correction, mastery and deletion semantics except backup scrub |

## Limitation

After removal of JSON import/export and app-managed backups, the application
provides no built-in rollback or restore path for subsequently registered
vocabulary data. Registration safety relies on atomic validation before
commit.

## Verification Required

- Full XCTest and macOS build because persistence models and user-facing
  deletion/settings flows change.
- Verify the removed JSON controls are absent from Settings.
- Verify bulk intake preserves internal punctuation in a sampled registered
  item, stores exactly 100 words for the explicit Seoul date and does not
  create attempts or review priority.

## Implemented Evidence

- Debug XCTest passed with the removed backup tests no longer part of the
  product contract: 15 tests passed.
- Release build and app launch verification passed after removing the backup
  model/service/UI.
- An explicit-date operator intake stored 100 words for `2026-05-25`;
  internal-punctuation and multiple-meaning integrity checks passed without
  recording identifiable vocabulary in this decision record.
- The prior app-managed backup residual directory was removed after its
  functionality was deleted.

## Active Override

`CL-0004` replaces the local operator-tool portion of this decision with an
in-app paste intake flow. The JSON and managed-backup removal contract remains
active.
