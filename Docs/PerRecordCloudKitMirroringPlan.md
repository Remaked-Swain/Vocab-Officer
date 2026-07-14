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
- `cloudKitPrivate` exists in `VocabModelContainerFactory`, but
  `VocabSyncMode.current()` intentionally falls back to `.localOnly` unless
  CloudKit is explicitly allowed at container creation time.
- Snapshot sync is implemented with one CloudKit snapshot record and a local
  cursor. It is useful as a recovery/fallback path but does not provide
  per-record merge.
- Both macOS and iOS targets have the `iCloud.com.swainyun.Vocab` entitlement.

## Non-Negotiable Safety Rules

- Do not open the production local store directly as a CloudKit-backed store
  during first migration.
- Do not delete `Vocab.store`, its WAL or SHM files as part of enabling
  mirroring.
- Create a local checkpoint before any destructive replace, import or mode
  switch.
- Keep snapshot export/import available until mirrored mode is proven on both
  Mac and iPhone with real data.
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
5. Import the snapshot into `VocabMirrored.store`.
6. Verify word count, daily set count and relationship integrity.
7. Persist `.cloudKitPrivate`.
8. Ask the user to relaunch, or rebuild the root container through an app-level
   restart flow.

Rollback is just switching the mode flag back to `.localOnly`. The local store
remains untouched.

## Sync Scope

Initial mirrored scope should include:

- `WordRecord`
- `MeaningRecord`
- `DailySetRecord`
- `DailySetItemRecord`
- `ReviewStateRecord`
- `TestSessionRecord`
- `AttemptRecord`

Local-only or deferred scope:

- `MemoryAidCacheRecord`: generated content can be recreated and may be large.
- `AnonymousAggregateRecord`: can be recomputed or kept local until a clear
  cross-device analytics need exists.

If SwiftData cannot split one schema across local-only and CloudKit-backed
stores cleanly, keep these records in the mirrored schema temporarily but do
not rely on them for cross-device UX until storage behavior is measured.

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

- Add a safe test/harness that creates a CloudKit-configured container in a
  temporary store URL, never the production `Vocab.store`.
- Verify the current schema can open under `.private`.
- Add tests for separate local and mirrored store URLs.
- Do not expose mirrored mode in the UI yet.

### Phase 2: Migration Service

- Add `VocabStoreMigrationService`.
- Export from local store and import into mirrored store.
- Verify counts and relationship integrity.
- Store migration status and last checkpoint directory.
- Add rollback-by-mode-switch helper.

### Phase 3: UI Gate

- Add a Mac settings flow: readiness check, checkpoint confirmation, migration,
  relaunch guidance, rollback option.
- iOS should open mirrored mode only after entitlement/account readiness and
  should show clear recovery guidance if the mirrored container fails.

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

- Unit tests for URL separation and mode selection.
- Unit tests for migration count/relationship integrity.
- Build macOS and iOS targets.
- Real-device check:
  - Mac creates a set, iPhone observes it.
  - iPhone completes a test, Mac observes attempts/review state.
  - Mac edits a word meaning, iPhone observes it.
  - Delete/tombstone behavior is verified before enabling destructive deletes.

## Open Questions

- Whether the current `@Attribute(.unique)` IDs are acceptable in the
  CloudKit-backed SwiftData schema.
- Whether current array fields are acceptable for conflict-heavy data.
- Whether `MemoryAidCacheRecord` and `AnonymousAggregateRecord` should remain
  in the mirrored schema or be moved to a separate local-only store.
- Whether app restart is acceptable after switching stores, or whether the app
  should rebuild the model container in-process.
