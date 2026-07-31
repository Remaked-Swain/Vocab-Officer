# CL-0024: Multiple Choice Test Mode

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-31 (Asia/Seoul) |
| Scope | Test question format, Mac/iOS test UX, persistence, snapshot sync |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while multiple-choice testing, attempt history, or snapshot sync exists |

## Decision

- Add a test question format axis separate from `SessionMode`.
  `QuestionFormat` has `.typed` for the existing direct-answer mode and
  `.multipleChoice` for the new four-choice mode.
- A multiple-choice question contains one correct option and three distractor
  options. If there are not enough unique distractors, that question is
  excluded. If no questions remain for the requested session, session
  generation fails with `noSessionCandidates`.
- Distractor candidates are shuffled with a session/question/target/direction
  seed before the three wrong options are selected. This prevents the same
  front-loaded wrong choices from repeating across sessions while keeping a
  generated session stable during rendering.
- Multiple-choice attempts store the user-facing selected option label in the
  attempt history, not the transient option identifier.
- Multiple-choice correct answers contribute to review relief and streak
  progress, but they do not contribute to `Mastered` success-day history.
  `Mastered` remains evidence of unaided recall because choosing from visible
  options is materially easier than producing the answer without choices.

## Data And Sync

- `AttemptRecord` and `TestSessionRecord` include `questionFormatRaw`.
- Snapshot attempt and session payloads include `questionFormatRaw`.
- Existing snapshot decode defaults a missing `questionFormatRaw` to `.typed`
  so older backups and mirrored payloads remain readable.
- The canonical attempt signature includes `questionFormatRaw` so iCloud
  reconciliation can detect format changes as meaningful attempt data.
- SwiftData schema V4 was added. V3 freezes the model graph before
  `questionFormatRaw`; V2 freezes the V3 graph without
  `BootstrapExportReceipt`, keeping older schema checksums isolated from the
  current model graph.

## UI

- macOS and iOS test setup screens expose a question format picker.
- macOS shows multiple-choice options in a two-column grid and supports number
  key selection with `1` through `4`.
- iOS uses touch-first vertical option buttons sized for the phone layout.
- Correction UI does not offer alias insertion for multiple-choice answers.
  Alias insertion remains a direct-answer correction feature.

## Evidence

- `./script/verify_changed.sh` passed.
- `VocabIOS` generic iOS build passed.
- A focused regression test verifies that multiple-choice distractor sets can
  vary between generated sessions.
- Monitor approved the change set.

## Limitations

- Long Korean meaning choices still need real-device QA for wrapping, cell
  height and tap target comfort.
- Different wrong-choice combinations are randomized per generated session, but
  finite candidate pools mean the app cannot mathematically guarantee that two
  separate sessions never repeat the same wrong-choice set.

## Relationship

This record extends the existing test, review and iCloud records without
changing their session-mode policy. `SessionMode` still decides the source of
candidate words; `QuestionFormat` decides how each selected word is answered.
