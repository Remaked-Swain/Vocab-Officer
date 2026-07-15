# Per-Record CloudKit Mirroring Plan

> Implementation status (2026-07-15): mirrored mode no longer runs automatic
> snapshot batch transport. iOS connects directly without seeding local data;
> only Mac may perform guarded first bootstrap after both explicit confirmation
> and an atomic private-CloudKit claim. Store-open failures are explicit and never fall back to a
> writable production local store. Snapshot transport is manual recovery only.

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
  cannot open, the app uses an in-memory recovery UI container and surfaces a
  connection error. It does not open writable `Vocab.store`.
- Snapshot sync is implemented with one CloudKit snapshot record and a local
  cursor. It is useful as a recovery/fallback path but does not provide
  per-record merge.
- Both macOS and iOS targets have the `iCloud.com.swainyun.Vocab` entitlement.
- macOS Settings exposes a guarded migration action. It requires CloudKit
  readiness, creates a local checkpoint, rehearses opening that checkpoint,
  atomically claims or resumes the fixed private CloudKit record
  `VocabBootstrapClaim-v1`, copies or supplements a full-fidelity snapshot by
  UUID, verifies the snapshot fingerprint and expected ID sets, then switches
  the next launch to mirrored mode. Only a newly created claim requires an
  empty mirrored store; same-tuple retries resume partial work.
- SwiftData model IDs are app-managed UUID values without `@Attribute(.unique)`
  because CloudKit mirroring must not depend on unique constraints.
- Mirrored startup is gated by bootstrap metadata and expected entity counts.
  Mutation is unavailable until hydration reaches `ready`.
- The bootstrap tuple and originating device ID are stored in Keychain. A
  one-time migration moves the old pending UUID pair out of UserDefaults only
  after the Keychain write succeeds. An Application Support recovery manifest
  binds the checkpoint path, canonical domain fingerprint and full claim tuple.

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
5. Use `CKModifyRecordsOperation` with `isAtomic = true` and
   `.ifServerRecordUnchanged` to claim the fixed server record. A foreign
   existing tuple, competing mutation, unknown result or unconfirmed timeout
   fails closed; the exact same tuple may resume.
6. For a newly created `claimed` record, require an empty mirrored store. For
   the exact same tuple, resume `claimed` or `seeding` work without deleting
   existing mirrored records. A foreign tuple fails closed.
7. Import snapshot v2 by UUID, save, verify the complete fingerprint and
   expected ID sets, then transition `claimed -> seeding`. Keep the bootstrap
   mirrored container alive while export is pending.
8. Register the export observer before the seed/probe save. Persist a
   `BootstrapExportReceipt` containing request ID, source fingerprint, store
   UUID, transaction boundary, probe generation, state and nonce in the same
   save as the first import. A later no-op save never replaces that boundary.
9. On `seeding` resume, increment generation, replace the nonce and persist that
   receipt update as a durable probe transaction. Accept only a clean successful
   export for the same store/request/fingerprint whose start is on or after the
   active receipt boundary. Export error or timeout leaves the claim at
   `seeding`.
10. Only after that export succeeds, transition `seeding -> completed`. A
   subsequently observed `completed` server claim switches to mirrored
   hydration without invoking bootstrap import or reseeding.
11. Reconcile tombstones and replay canonical Attempts only after completion.
12. Persist `.cloudKitPrivate` and show completion only after server completion.
13. Ask the user to relaunch, or rebuild the root container through an app-level
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

Implemented conflict shape:

- Keep Attempts as durable append-only learning facts in mirrored mode.
- Group Attempts by `(sessionID, questionIndex)`. Identical payload duplicates
  use the lowest UUID as the canonical fact. Differing payloads are an explicit
  conflict: neither fact is applied and hydration exposes the failure.
- Sort canonical Attempts by `(answeredAt, id)` and recalculate review summaries
  after hydration and remote-store notifications, including late past facts.
- Apply tombstones idempotently; tombstones always win for Word, Meaning,
  DailySet and DailySetItem with the same UUID.

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
- Added `VocabSchemaV1`, `VocabSchemaV2` and a lightweight migration plan.
  `VocabSchemaV1` is an exact nested-type reproduction of the previous commit's
  nine-model unversioned production schema, including fields, defaults,
  optional relationships, inverses and delete rules. A real temporary SQLite
  V1 fixture is closed, migrated through the production factory at the same
  URL, modified, closed and reopened. IDs, relationships, arrays, judgements,
  progress, counts and new sync defaults are asserted; production store files
  are never opened by this test.

### Phase 3: UI Gate

- Added a Mac settings flow: readiness check, confirmation, checkpoint,
  migration, relaunch guidance and rollback option.
- macOS and iOS startup surface an explicit connection error over an in-memory
  recovery UI if the mirrored container fails.

### Phase 4: Domain Conflict Hardening (implemented)

- Converted synced user-content delete paths to tombstone-first behavior.
- Added `WordRecord.activeMeanings` as the shared prompt, grading, correction,
  mastery, card, search/detail, speech, snapshot and UI path.
- Made `ReviewStateRecord` and meaning success days rebuildable from all unique
  Attempt facts.
- Replace merge-sensitive arrays with child records if tests show concurrent
  append loss.

### Phase 5: Snapshot Recovery Isolation (implemented)

- Keep explicit snapshot backup/recovery paths.
- Automatic snapshot batch sync is disabled. Snapshot v1 is local-only and
  mirrored whole-store replacement is rejected for every version.
- Snapshot v2 carries and validates `updatedAt`, `originDeviceID` and
  `deletedAt` for every mirrored payload, includes all Attempts and tombstones
  in its fingerprint, and intentionally excludes the server bootstrap claim.
- The canonical fingerprint is domain-only: export time, sync metadata,
  reconciliation timestamps, receipt/probe state and per-record merge
  bookkeeping do not change it. Record identity, content, relationships,
  append-only facts and whether a record is deleted remain fingerprinted.
  `Word.statusRaw`, `Meaning.successDays` and `ReviewState` are excluded because
  they are replay-derived from canonical Attempts; replaying the same facts on
  another device therefore cannot invalidate bootstrap recovery ownership.
- Manual recovery upload compares the server snapshot's canonical fingerprint.
  Equal content reports "변경 없음" and skips the asset write. Different
  content uses a conditional full upload and aborts if the server metadata
  changes between inspection and save.

### Phase 6: Resumable Atomic Bootstrap Claim (implemented, server integration pending)

- A protocol-backed claim service lets normal tests cover competing, existing,
  foreign, unknown, timeout and response-loss outcomes without network access.
- The production service targets the private database and fixed record name
  `VocabBootstrapClaim-v1`. The non-deletable record stores `claimed`,
  `seeding` or `completed` plus `(claimID, requestID, ownerDeviceID,
  sourceFingerprint, schemaVersion)`. Atomic conditional transitions and
  timeout refetches succeed only for that exact tuple and expected state.
- Same-tuple retries resume. `claimed` imports by UUID; `seeding` supplements
  missing UUIDs only after inspecting IDs/counts/fingerprint; `completed`
  verifies and returns without reseeding. Foreign ownership fails closed.
- A local UI UUID token is only confirmation input. It cannot authorize import
  without matching server ownership and state.
- Settings fetches the fixed server claim before creating any token and exposes
  its full tuple, state and server times. `claimed`/`seeding` resumes only with
  the matching Keychain tuple. If that tuple was lost, recovery additionally
  requires matching current/checkpoint canonical fingerprint, schema and a
  valid persisted export receipt. Foreign mismatch remains fail-closed; there
  is no claim deletion or takeover path.
- Local SwiftData save is not proof of CloudKit upload. The claim remains
  `seeding` until a successful, matching-store export event is observed. The
  Settings task strongly retains the bootstrap `ModelContainer` until export
  success or an explicit export error/timeout.
- The receipt model is introduced by schema V3 through a lightweight V2-to-V3
  migration; existing V1/V2 stores are opened in place and are never reset.

### Phase 7: iPhone Hydration Diagnostics (implemented)

- iPhone Settings queries account state, the fixed server claim and local
  hydration together. Missing claim means Mac first migration is required;
  `claimed`/`seeding` means Mac upload is in progress; `completed` without local
  metadata means import is delayed.
- Completed-without-metadata has a bounded grace period and becomes an explicit
  diagnostic error with a manual recheck action instead of waiting forever.
- Manual refresh reevaluates all three inputs. Successful CloudKit import events
  refresh immediately. Polling runs only while the app is foreground-active and
  hydration is `awaitingBootstrapMetadata` or `hydrating`.

### Phase 8: Mac Recovery Status UI (implemented)

- Settings uses a resizable minimum/ideal window instead of a fixed width.
  Long status and claim tuple text has no line limit and is selectable.
- Button groups use `ViewThatFits` to fall back from horizontal to vertical
  layout. Status text describes upload, completion and hydration without
  claiming that eventual CloudKit propagation is already current.

## Verification Gates

- Unit tests for URL separation and mode selection: passed.
- Unit tests for migration fingerprint/relationship integrity: passed.
- Unit tests for blocking migration into a non-empty mirrored store: passed.
- Unit tests for checkpoint restore rehearsal: passed.
- Receipt/export-gate focused claim, container migration, hydration and snapshot
  tests: 42 passed, 0 failures (`/tmp/VocabReceiptFocused`); the final
  deterministic export-gate suite passed 12 of 12 tests.
- macOS changed-file test suite: passed.
- Final macOS XCTest: 175 passed, 3 skips, 0 failures
  (`/tmp/VocabMinimalReworkFull-20260715.xcresult`). The skips are two
  performance gates and the opt-in CloudKit integration test.
- Final iOS simulator build: passed with signing disabled
  (`/tmp/VocabMinimalReworkIOS`).
- Signed Mac Debug build: passed with an Apple Development identity
  (`/tmp/VocabFourthFinalSignedMac`). Strict deep verification passed, and the
  embedded entitlement dump and generated `.xcent` carry
  `iCloud.com.swainyun.Vocab` plus the `CloudKit` service entitlement.
- Real CloudKit-backed open/close is opt-in with
  `VOCAB_RUN_CLOUDKIT_INTEGRATION=1`; it has not run in the current environment.
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
