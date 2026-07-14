# CL-0016: Per-Record CloudKit Mirroring Migration

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-14 (Asia/Seoul) |
| Scope | `Vocab/App/VocabModelContainerFactory.swift`, `Vocab/App/VocabSyncSnapshot.swift`, `Vocab/App/VocabLocalStoreCheckpoint.swift`, `Vocab/App/VocabApp.swift`, `VocabIOS/App/VocabIOSApp.swift`, Settings migration UI, per-record migration tests |
| Agents | Director, Monitor, Recorder |
| Archive review | retain while per-record CloudKit mirroring or migration behavior exists |

## Decision

- The final Vocab multi-platform sync target is per-record SwiftData CloudKit
  mirroring, not snapshot batch transport.
- Snapshot batch sync remains as a fallback and recovery path until mirroring is
  proven with real Mac and iPhone data.
- The existing local store must not be opened directly as a CloudKit-backed
  store during first migration.
- Local-only mode uses `Vocab.store`.
- CloudKit mirrored mode uses a separate `VocabMirrored.store`.
- The sync mode flag must not be switched to mirrored mode until migration,
  verification and rollback protections are implemented.
- Any migration from local to mirrored storage must create a checkpoint first
  and must preserve the production local store.
- Migration must not replace a non-empty mirrored store, because deletes and
  inserts may propagate to iCloud.
- SwiftData model IDs are app-managed UUIDs, not `@Attribute(.unique)`, because
  the CloudKit-mirrored schema must not rely on unique constraints.
- Migration uses the snapshot format as a transfer object, but the transfer is
  now full-fidelity for the current SwiftData schema: words, meanings, review
  state, daily sets, sessions, attempts, anonymous aggregates and memory-aid
  caches.
- Older snapshot JSON that lacks the newly added full-fidelity collections must
  continue to decode with empty collections.

## Monitor Blockers

The first high-level plan was blocked because:

- SwiftData CloudKit model compatibility is not yet proven.
- `localOnly` and `cloudKitPrivate` previously shared the same `Vocab.store`
  path.
- Snapshot import is not full fidelity.
- File-copy checkpoints need stronger consistency guarantees before they can
  be trusted as migration rollback.
- App startup still uses `fatalError` on container creation failure.

## Implemented In This Step

- Added `Docs/PerRecordCloudKitMirroringPlan.md`.
- Split store URLs so `.localOnly` maps to `Vocab.store` and
  `.cloudKitPrivate` maps to `VocabMirrored.store`.
- Preserved legacy `default.store` migration only for the local store.
- Added tests that lock local/mirrored URL separation and verify a temporary
  CloudKit configuration can be built without touching the production store.
- Expanded `VocabSyncSnapshot` to include `TestSessionRecord`,
  `AttemptRecord`, `AnonymousAggregateRecord` and `MemoryAidCacheRecord`.
- Added backward-compatible snapshot decoding for older JSON without the new
  full-fidelity collections.
- Added `VocabStoreMigrationService`, which checkpoints the local store,
  imports a full-fidelity snapshot into the mirrored store and verifies the
  mirrored export fingerprint before switching modes.
- Added a preflight that blocks migration when the mirrored store already has
  local mirrored records.
- Removed SwiftData `@Attribute(.unique)` constraints from model IDs for
  CloudKit mirroring compatibility; uniqueness remains enforced by app-level
  UUID generation and snapshot validation.
- Added checkpoint restore rehearsal that opens the copied SwiftData store and
  confirms core record counts.
- Replaced launch-time mirrored-container fatal termination with local-only
  fallback plus user-facing warning.
- Added macOS Settings UI for guarded per-record migration and rollback by
  mode switch.

## Remaining Work

- Run signed Mac and real iPhone smoke tests with the same iCloud account.
- Confirm CloudKit schema behavior for non-optional fields and array
  properties under real per-record mirroring.
- Verify cross-device flows: Mac set creation appears on iPhone, iPhone test
  attempts appear on Mac, and Mac meaning edits appear on iPhone.
- Keep destructive delete behavior conservative until tombstone/delete
  propagation is verified on real devices.

## Verification

- `git diff --check`
- `./script/verify_changed.sh Vocab/App/VocabModelContainerFactory.swift VocabTests/App/VocabModelContainerFactoryTests.swift Docs/PerRecordCloudKitMirroringPlan.md`
- `xcodebuild -project Vocab.xcodeproj -scheme VocabIOS -configuration Debug -derivedDataPath /tmp/vocab-ios-mirroring-plan-build -destination generic/platform=iOS\ Simulator CODE_SIGNING_ALLOWED=NO build`
- `./script/verify_changed.sh Vocab/App/VocabSyncSnapshot.swift VocabTests/App/VocabSyncSnapshotTests.swift Vocab/App/VocabLocalStoreCheckpoint.swift VocabTests/App/VocabLocalStoreCheckpointTests.swift Vocab/App/VocabApp.swift VocabIOS/App/VocabIOSApp.swift Vocab/Presentation/RootView.swift VocabIOS/Presentation/VocabIOSRootView.swift`
- `xcodebuild -project Vocab.xcodeproj -scheme VocabIOS -configuration Debug -derivedDataPath /tmp/vocab-ios-mirroring-final-build -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

## Relationships

This supersedes the out-of-scope per-record mirroring note in `CL-0014` for
future migration work. `CL-0014` remains active for snapshot batch sync until
per-record mirroring is fully enabled and verified.
