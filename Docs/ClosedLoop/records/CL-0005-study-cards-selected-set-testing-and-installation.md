# CL-0005: Study Cards, Selected-Set Testing And Local Installation

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-05-26 (Asia/Seoul) |
| Scope | `Vocab/Application/`, `Vocab/Presentation/`, `VocabTests/`, `script/`, `Docs/` |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | Retain while testing, card study or local installation workflows exist |

## Decision

Completed intake sets remain independently selectable for testing. A newer
daily intake must not make an older untested set unreachable; a selected set
produces at most 20 unique questions with words never presented in any prior
session prioritized across Seoul dates.
Candidate-free starts do not persist an empty session or present the test
runner.

The application includes a set-grouped learning-card screen. Cards toggle
between their English headword and registered Korean meanings without creating
test progress or attempts.

For English-to-Korean grading, any individually registered meaning is an
automatic correct answer and retains its own meaning identifier for mastery
tracking. For an automatic correct or incorrect judgement, the acknowledgement
panel exposes the headword, all registered meanings and the submitted answer
before final confirmation or manual correction. The unknown action remains an
immediate explicit failure path and does not require that review panel.

A legacy meaning value containing delimiters is not eligible for automatic
matching or corrected mastery credit until it is represented as independent
meaning records. This prevents one combined identifier from satisfying several
core meanings.

Test session presentation owns the session record and its questions as one
value. It never assumes that a question exists while rendering, preventing the
previous empty-array trap during sheet creation.

Local installation is a supported operator action:
`script/build_and_run.sh --install-verify` installs a Release application at
`/Applications/Vocab.app` and verifies launch. The installed app uses the same
bundle identifier and local application-support data store.

## Relationship To Existing Decisions

- This record extends the testing and correction contracts of `CL-0001`.
- The JSON and managed-backup removal policy in `CL-0003` remains unchanged.
- The paste intake and repository privacy policy in `CL-0004` remains active.

## Privacy Boundary

Records and tests use synthetic fixtures only. Do not persist real vocabulary
payloads, local stores or raw crash reports as repository evidence.

## Verification Required

`RUN-20260526-CL0005` records the execution evidence for this decision. It
must cover selected-set and empty-candidate regressions, multiple-meaning
application grading, the full XCTest suite, Release installation and launch,
and repository privacy scanning.

## Limitation

Card-flip animation and acknowledgement-panel visual inspection require a
manual native macOS UI check unless UI automation access becomes available.
The automated test and build evidence verifies the underlying selection,
grading and crash-prevention behavior but does not claim pixel-level visual
interaction confirmation.
