# CL-0016: Per-Record CloudKit Mirroring Migration

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-14 (Asia/Seoul) |
| Scope | `Vocab/App/VocabModelContainerFactory.swift`, `VocabTests/App/VocabModelContainerFactoryTests.swift`, `Docs/PerRecordCloudKitMirroringPlan.md` |
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
- The current snapshot format is not full fidelity for migration because it
  excludes raw sessions, attempts, aggregates and memory-aid cache. Future
  migration work must either expand the transfer format or explicitly classify
  omitted data as disposable.

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

## Remaining Work

- Add a signed or explicit manual compatibility probe that actually opens a
  CloudKit-backed `ModelContainer` outside the production store.
- Decide whether unique attributes, non-optional fields and array properties
  are acceptable under SwiftData CloudKit mirroring.
- Implement full-fidelity migration or explicitly scoped data omission.
- Add checkpoint consistency and restore rehearsal tests.
- Replace app-start `fatalError` paths with recoverable fallback UI.
- Add migration/rollback UI only after the above blockers are resolved.

## Verification

- `git diff --check`
- `./script/verify_changed.sh Vocab/App/VocabModelContainerFactory.swift VocabTests/App/VocabModelContainerFactoryTests.swift Docs/PerRecordCloudKitMirroringPlan.md`
- `xcodebuild -project Vocab.xcodeproj -scheme VocabIOS -configuration Debug -derivedDataPath /tmp/vocab-ios-mirroring-plan-build -destination generic/platform=iOS\ Simulator CODE_SIGNING_ALLOWED=NO build`

## Relationships

This supersedes the out-of-scope per-record mirroring note in `CL-0014` for
future migration work. `CL-0014` remains active for snapshot batch sync until
per-record mirroring is fully enabled and verified.
