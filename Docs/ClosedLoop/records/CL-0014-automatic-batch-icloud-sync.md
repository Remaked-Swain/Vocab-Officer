# CL-0014: Automatic Batch iCloud Sync

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-14 (Asia/Seoul) |
| Scope | `Vocab/App/`, `Vocab/Presentation/RootView.swift`, `VocabIOS/`, sync tests |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while iCloud sync or migration behavior exists |

## Decision

- Automatic iCloud sync is batch-based and snapshot-cursor driven, not live
  CloudKit record mirroring.
- Manual snapshot upload/import remains the fallback and initial baseline
  creation path.
- Each successful upload/import records a local cursor containing the cloud
  export time and content fingerprint.
- Automatic sync can apply only safe one-sided changes:
  local-only changes upload, cloud-only changes download, matching state skips.
- If local and cloud have both changed since the cursor, automatic sync stops
  and reports a conflict instead of overwriting either side.
- Non-user-initiated automatic sync is deferred when there is no network,
  constrained network mode is active, Low Power Mode is active, iCloud account
  is unavailable, entitlement is missing, or no baseline cursor exists.
- Upload uses a conditional CloudKit save preflight. When an existing cloud
  snapshot is expected, `VocabCloudKitSnapshotStore.save(_:ifCloudMetadataMatches:)`
  must compare the expected metadata against the fetched `CKRecord` and save
  that same record so a cloud change between metadata preflight and save cannot
  be overwritten silently.
- Missing cloud records are upload conflicts when expected metadata exists.
  Creation is allowed only when the expected metadata is `nil`.
- `CKError.serverRecordChanged` is treated as a conflict result, not as a
  successful upload, and must not advance the local cursor.
- The sync cursor advances only after successful upload, successful download,
  or already-in-sync decisions.
- iOS manual import, iOS automatic download and macOS automatic download must
  create a local store checkpoint before destructively replacing local data.
  If checkpoint creation fails, replace and cursor advancement must stop.

## Excluded Scope

- This does not yet implement per-record CloudKit mirroring.
- This does not yet merge simultaneous edits to words, meanings, attempts,
  review state, daily sets, tombstones or memory-aid cache records.
- This does not remove the local-first macOS store or make iCloud the only
  source of truth.

## Verification

- Added focused tests for upload/download/conflict/blocked batch decisions.
- Added a fake store race test that mutates cloud state after conditional fetch
  but before save, verifying no overwrite and no cursor advancement.
- Verified macOS app build with `CODE_SIGNING_ALLOWED=NO`.
- Verified iOS simulator build.
- Focused XCTest still hit an app-host bootstrap trap in the local Xcode test
  runner, so the accepted verification for this step is build-level plus
  code-level sync decision tests in source. Re-run XCTest after the existing
  app-host SwiftData test instability is isolated.

## Follow-up Approval Notes

Monitor rejected the first upload guard because a metadata preflight followed
by an unconditional save left a time-of-check/time-of-use window. The approved
follow-up closed that window with the conditional save behavior above.

Monitor later rejected the first destructive-download hardening pass because
the macOS automatic sync call site still constructed the sync service without
a checkpoint creator. The approved follow-up injected checkpoint creation into
the macOS RootView automatic sync path, kept the iOS manual import and iOS
automatic download checkpoint guard, and expanded success messaging/tests so a
successful download can expose the checkpoint directory name.

The iOS QA follow-up approved raising the iOS deployment target to 26 because
that build setting is not a local store deletion, store path change, bundle id
change, schema migration or data reset. The iOS app must not use private
`SecTask` runtime entitlement shims; when entitlement inspection is unavailable
on iOS, readiness should leave CloudKit requests possible and let signed-build
entitlement inspection or actual CloudKit account/operation failures expose
provisioning problems. Sync status and CTA UI must stay out of the tab bar
area, with staged sync actions moved into the Sync tab. The iPhone 12 mini
compact-first layout changes still require real-device verification.

Recorder close addendum: the iPhone 12 mini screenshot issue was likely not
only internal SwiftUI sizing. A missing iOS launch screen could leave the app
displayed in letterboxed compatibility mode, so the accepted fix added
`VocabIOS/LaunchScreen.storyboard`, registered it in the iOS resources phase,
and set `INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen` for iOS Debug
and Release. The iOS empty state was also replaced with `CompactEmptyState`,
and wrapping was hardened for `SyncStepRow`, long sync messages and CloudKit
identifiers. The deployment targets stayed at
`IPHONEOS_DEPLOYMENT_TARGET = 26.0` and `MACOSX_DEPLOYMENT_TARGET = 14.0`.
Verification passed with an iOS Simulator generic build, and the built
`Info.plist` contained `UILaunchStoryboardName = LaunchScreen`.

Still out of scope: SwiftData CloudKit mirroring, per-record merge, tombstone
replay, CloudKit change-token sync and field-level merge. Future work that adds
any of those must create or update a separate decision record.

Recorder close addendum 2026-07-14: Mac and iOS now trigger automatic batch
sync after `LearningCoordinator` write operations by posting
`vocabLearningStoreDidChange`. The root views do not run CloudKit immediately
for every write; they debounce learning-change notifications for two seconds
and preserve a pending reason when a sync is already running, so test sessions
do not fan out into per-question CloudKit uploads while the final state still
gets a follow-up sync opportunity. iOS also shares the real
`LearningCoordinator`-backed test flow and study-set card flip interaction
instead of using a read-only placeholder test screen. Verified with
`diff --check`, `VocabIOS` iOS Simulator Debug build, and changed-file
verification through `script/verify_changed.sh`.

## Relationships

This extends `Docs/iCloudIOSSyncPlan.md` and preserves the manual snapshot
transport from the initial iCloud/iOS sync work. It follows `CL-0012` by using
role-separated review and recording while keeping the durable record short.
