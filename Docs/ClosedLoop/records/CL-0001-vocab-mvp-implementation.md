# CL-0001: Vocab MVP Implementation

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-05-25 (Asia/Seoul) |
| Scope | `Vocab/`, `VocabTests/`, `Vocab.xcodeproj`, product acceptance |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | Retain while the application uses these data contracts |

## Decision

Implement the local macOS application with SwiftUI and SwiftData for
`com.swainyun.Vocab`, targeting macOS 14 or newer. The accepted domain
contracts include daily completed intake of exactly 100 new words, repeatable
sessions of at most 20 distinct words, bidirectional grading with explicit
manual correction, historical `failureCheck`, separate `activePriority`,
Mastered lifecycle, explicit deletion and managed JSON backup scrubbing.

Backup export schema version 2 preserves stable identifiers and creation dates;
schema version 1 is restored compatibly while dropping stale meaning links
that cannot be reliably reconnected.

## Monitor Findings And Resolution

| Finding | Resolution |
| --- | --- |
| Daily intake could partially insert before a late invalid meaning was detected. | Validate all 100 drafts before insertion. |
| Manual corrected English-to-Korean answers could credit the wrong or no core meaning. | Require a confirmed core meaning for corrected successful answers, including the `unknown` path. |
| Backup restore did not preserve identifiers and creation dates or migrate old snapshots safely. | Preserve v2 identifiers/timestamps and decode v1 with stale meaning links cleared. |
| Backup work could execute on UI-owned state and review selection rules diverged. | Move backup work to a model actor and standardize review eligibility on `activePriority > 0`. |

## Evidence

- Debug XCTest: 17 passed, 0 failed.
- XCTest result bundle:
  `test-build/Logs/Test/Test-Vocab-2026.05.25_22-37-20-+0900.xcresult`
- Release build succeeded.
- `script/build_and_run.sh --verify` succeeded.
- Monitor found no remaining blocking code issue after correction flows and
  backup migration handling were amended.

## Limitation

The large-fixture p95 performance acceptance in `Docs/Performance.md` was not
measured. Performance scope may be reopened when measurement is performed.
## Active Override

`CL-0003` removes the JSON import/export and app-managed backup creation,
restore and scrub portions of this record. Its remaining intake, testing,
correction, mastery and deletion contracts stay active.
