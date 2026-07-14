# Per-Record CloudKit Mirroring Plan

## Goal

Move Vocab from guarded snapshot batch sync toward SwiftData per-record
CloudKit mirroring so the Mac and iPhone apps can share vocabulary, study
sets, tests and review state without manual upload/download.

The migration must preserve the current macOS vocabulary database. A failed
CloudKit setup, provisioning issue, schema issue or first-device conflict must
not delete or rewrite the existing local store.

## Current State

- The app currently opens `Vocab.store` in local-only mode by default.
- `cloudKitPrivate` opens a separate `VocabMirrored.store` with
  `cloudKitDatabase: .private("iCloud.com.swainyun.Vocab")`.
- The launch path reads the persisted sync mode. If the mirrored container
  cannot open, the app falls back to local-only mode and surfaces a warning
  instead of terminating.
- Snapshot sync is implemented with one CloudKit snapshot record and a local
  cursor. It is useful as a recovery/fallback path but does not provide
  per-record merge.
- Both macOS and iOS targets have the `iCloud.com.swainyun.Vocab` entitlement.
- macOS Settings exposes a guarded migration action. It requires CloudKit
  readiness, creates a local checkpoint, rehearses opening that checkpoint,
  confirms `VocabMirrored.store` is empty, copies a full-fidelity snapshot,
  verifies the snapshot fingerprint, then switches the next launch to mirrored
  mode.
- SwiftData model IDs are app-managed UUID values without `@Attribute(.unique)`
  because CloudKit mirroring must not depend on unique constraints.

## Non-Negotiable Safety Rules

- Do not open the production local store directly as a CloudKit-backed store
  during first migration.
- Do not delete `Vocab.store`, its WAL or SHM files as part of enabling
  mirroring.
- Create a local checkpoint before any destructive replace, import or mode
  switch.
- Keep snapshot export/import available until mirrored mode is proven on both
  Mac and iPhone with real data.
- Do not import into a mirrored store that already contains local mirrored
  records; this prevents accidental deletion or overwrite propagation.
- Treat simultaneous cross-device edits as an explicit conflict design topic,
  not as something automatically solved by last-writer-wins.

## Proposed Store Topology

- `Vocab.store`: existing local-only production store.
- `VocabMirrored.store`: new SwiftData store configured with
  `cloudKitDatabase: .private("iCloud.com.swainyun.Vocab")`.

The app chooses the store at launch from a persisted sync mode:

- `.localOnly`: open `Vocab.store`.
- `.cloudKitPrivate`: open `VocabMirrored.store`.

The mode flag changes only after a migration transaction completes:

1. Check account, entitlement and runtime readiness.
2. Create a local checkpoint of `Vocab.store`.
3. Export a validated snapshot from `Vocab.store`.
4. Create or open `VocabMirrored.store`.
5. Refuse migration if `VocabMirrored.store` already contains mirrored records.
6. Import the snapshot into `VocabMirrored.store`.
7. Verify a stable content fingerprint after re-export from the mirrored store.
8. Persist `.cloudKitPrivate`.
9. Ask the user to relaunch, or rebuild the root container through an app-level
   restart flow.

Rollback is just switching the mode flag back to `.localOnly`. The local store
remains untouched.

## Sync Scope

Mirrored migration scope includes:

- `WordRecord`
- `MeaningRecord`
- `DailySetRecord`
- `DailySetItemRecord`
- `ReviewStateRecord`
- `TestSessionRecord`
- `AttemptRecord`
- `AnonymousAggregateRecord`
- `MemoryAidCacheRecord`

`MemoryAidCacheRecord` and `AnonymousAggregateRecord` are included for
full-fidelity migration because the current app uses one SwiftData schema per
container. They can be split later only if storage growth or CloudKit traffic
becomes measurable enough to justify the complexity.

## Conflict Policy

SwiftData CloudKit mirroring can move records between devices, but Vocab still
needs domain-level conflict rules:

- `AttemptRecord` should be append-only.
- `ReviewStateRecord` is a derived summary and is vulnerable to lost updates
  if two devices update streaks or counters concurrently.
- `MeaningRecord.successDays`, aliases and `TestSessionRecord.wordIDs` are
  arrays and may not merge as append-only sets under concurrent edits.

Long-term safest shape:

- Keep attempts/events as the durable source of learning truth.
- Recalculate review summaries when needed or after merge-sensitive imports.
- Prefer tombstones (`deletedAt`) over hard delete for synced word lifecycle
  until delete propagation is proven.

## Implementation Phases

### Phase 1: Compatibility Probe

- Added tests that create a CloudKit-configured container in a temporary store
  URL, never the production `Vocab.store`.
- Verified separate local and mirrored store URLs.

### Phase 2: Migration Service

- Added `VocabStoreMigrationService`.
- Export from local store and import into mirrored store using the full
  snapshot shape.
- Verify by comparing source and mirrored content fingerprints.
- Added checkpoint restore rehearsal before the mode switch.
- Added rollback-by-mode-switch helper in Settings.

### Phase 3: UI Gate

- Added a Mac settings flow: readiness check, confirmation, checkpoint,
  migration, relaunch guidance and rollback option.
- macOS and iOS startup both fall back to local-only mode with guidance if the
  mirrored container fails.

### Phase 4: Domain Conflict Hardening

- Convert synced delete paths to tombstone-first behavior.
- Make `ReviewStateRecord` safely rebuildable from attempts and meaning day
  records.
- Replace merge-sensitive arrays with child records if tests show concurrent
  append loss.

### Phase 5: Snapshot Fallback De-emphasis

- Keep snapshot backup/recovery paths.
- Remove automatic snapshot batch sync once per-record mirroring is verified
  on real Mac/iPhone data and no longer needed as transport.

## Verification Gates

- Unit tests for URL separation and mode selection: passed.
- Unit tests for migration fingerprint/relationship integrity: passed.
- Unit tests for blocking migration into a non-empty mirrored store: passed.
- Unit tests for checkpoint restore rehearsal: passed.
- macOS changed-file test suite: passed.
- iOS simulator build: passed.
- Real-device check still required:
  - Mac creates a set, iPhone observes it.
  - iPhone completes a test, Mac observes attempts/review state.
  - Mac edits a word meaning, iPhone observes it.
  - Delete/tombstone behavior is verified before enabling destructive deletes.

## Open Questions

- Whether current array fields are acceptable for conflict-heavy data.
- Whether `MemoryAidCacheRecord` and `AnonymousAggregateRecord` should remain
  in the mirrored schema or be moved to a separate local-only store.
- Whether app restart is acceptable after switching stores, or whether the app
  should rebuild the model container in-process.
