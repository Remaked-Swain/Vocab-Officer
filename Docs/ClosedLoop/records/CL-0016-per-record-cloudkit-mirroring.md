# CL-0016: Per-Record CloudKit Mirroring Migration

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-14 (Asia/Seoul) |
| Scope | per-record SwiftData CloudKit mirroring, fixed bootstrap claim, hydration/reconciliation, snapshot v2, production-schema migration and cross-platform verification |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while per-record CloudKit mirroring or migration behavior exists |

## Decision

- The final Vocab multi-platform sync target is per-record SwiftData CloudKit
  mirroring, not snapshot batch transport.
- Snapshot transport remains only as an explicit local recovery/export path.
  Mirrored mode never runs automatic snapshot batch synchronization.
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
- Replaced launch-time mirrored-container fatal termination with an in-memory
  recovery UI container, not a writable production local-store fallback.
- Added macOS Settings UI for guarded per-record migration and rollback by
  mode switch.

## Executor Completion Update (2026-07-14)

- Removed app-launch, app-activation and learning-change snapshot batch calls
  from both platform roots. Snapshot upload remains an explicit macOS recovery
  operation and the automatic policy returns false for mirrored mode.
- iOS now defaults to opening `VocabMirrored.store` on first launch without
  importing or uploading an iPhone-local snapshot. macOS remains local until
  its guarded bootstrap migration succeeds.
- Mac bootstrap now requires an explicit one-time `VocabBootstrapToken`, an
  absent `CloudBootstrapRecord`, and empty mirrored content. It checkpoints
  `Vocab.store`, imports and verifies snapshot v2, writes metadata, and only
  then persists mirrored mode. iOS rejects this API and never seeds.
- A mirrored-store open failure no longer opens writable `Vocab.store` as a
  fallback. The app presents an explicit connection/recovery state over an
  in-memory UI container; production stores and checkpoints are untouched.
- All mirrored model types retain app UUIDs without unique constraints and now
  include defaulted `updatedAt`, `originDeviceID` and `deletedAt` metadata.
  Relationships use optional/nullify behavior. Added bootstrap metadata and
  independent tombstone records.
- User word, meaning, set and set-item deletion is tombstone-first. Tombstones
  win idempotently over active records with the same UUID. Active queries use
  `activeMeanings`; mirrored Attempt hard-delete compaction is disabled.
- Final Attempt records are append-only at the user workflow boundary.
  Mirrored reconciliation groups by `(sessionID, questionIndex)`. Identical
  payload duplicates select the lowest UUID; differing payloads apply neither
  fact and surface a hydration failure. Canonical facts sort by `(answeredAt,
  id)` and rebuild ReviewState and meaning success days, including late facts.
- Removed fixed synchronization banners. iOS Settings exposes connection/error
  state only; macOS Settings owns bootstrap, recovery snapshot and status UI.
- Added the hydration states `localOnly`, `awaitingBootstrapMetadata`,
  `hydrating`, `reconciling`, `ready`, and `failed`. Mirrored mutation remains
  gated until valid metadata and every expected entity count are observed.
- Snapshot v2 includes sync metadata, tombstones, Word/Meaning/Set/Item delete
  state, all Attempts, and `updatedAt`/`originDeviceID`/`deletedAt` for every
  mirrored payload in its fingerprint. The server claim is not snapshot data.
  v1 is local-only recovery and every mirrored whole-store replace is rejected.

## Executor Third-Pass Update (2026-07-14)

- Added a private CloudKit bootstrap claim service for fixed record name
  `VocabBootstrapClaim-v1`. Creation uses atomic
  `CKModifyRecordsOperation` with `.ifServerRecordUnchanged`; competing,
  foreign and unknown outcomes deny seeding. A timeout performs a follow-up
  fetch and succeeds only when the complete claim tuple and expected state
  match exactly.
- Mac import now requires both explicit UI confirmation and matching server
  claim approval. A generated local UUID cannot seed by itself. Existing claim
  records only lead to normal mirrored hydration; neither Mac nor iPhone
  reseeds an empty-looking mirrored store.
- Added `VersionedSchema` V1/V2 and a lightweight migration plan.
- Added an opt-in signed integration test that opens, closes and reopens a
  private CloudKit-configured `ModelContainer` at a unique temporary URL when
  `VOCAB_RUN_CLOUDKIT_INTEGRATION=1`. Normal tests use claim-service fakes.
- Hydration and Attempt replay errors are retained and displayed in macOS and
  iOS connection status UI instead of being reduced to an unexplained failed
  state.

## Executor Fourth-Pass Update (2026-07-14)

- `VocabSchemaV1` now reproduces the previous commit's complete unversioned
  production graph: all nine models, persisted fields, defaults, optionality,
  relationships, inverses and cascade rules. The migration test creates a real
  legacy SQLite store at a temporary URL, closes it, opens the same URL through
  the production factory and migration plan, verifies IDs, relationships,
  arrays, judgements, progress, counts and new sync defaults, then modifies,
  saves, closes and reopens it. Production store paths are never used.
- The fixed server claim is a persistent three-state record: `claimed`,
  `seeding`, `completed`. Ownership is the exact tuple `(claimID, requestID,
  ownerDeviceID, sourceFingerprint, schemaVersion)`. The same tuple resumes
  idempotently; a foreign tuple fails closed, and the claim is never deleted.
- A `claimed` retry imports by UUID, while a `seeding` retry verifies the
  mirrored fingerprint and expected UUID sets and supplements only missing
  records. `completed` verifies metadata/content and returns success without
  importing again. Transition timeouts and lost responses are resolved only by
  refetching the fixed record and matching both tuple and expected state.
- Network-free failure-injection tests cover import failure immediately after
  claim, partial save, completion timeout before server update, lost completion
  response, repeated same-tuple calls and foreign-tuple rejection. The resumed
  graph contains no duplicate Word, Meaning, DailySet or Attempt IDs.

## Closed-Loop Review Outcome

- The loop ran as sequential Director -> Executor -> Monitor handoffs. The
  Monitor issued three `REJECT` decisions, each returning work to the same
  Executor, and issued a code-level `APPROVE` on the fourth review.
- The approved code-level design removes automatic snapshot synchronization in
  favor of SwiftData CloudKit per-record mirroring. Snapshot v2 remains a
  bootstrap/recovery transfer format and preserves sync metadata, tombstones,
  all append-only Attempts and per-record update/origin/delete metadata.
- Bootstrap is Mac-only and requires the fixed atomic server claim. Unknown,
  competing or foreign claim outcomes fail closed; only the exact same request
  tuple may resume idempotently through `claimed`, `seeding` and `completed`.
  iPhone is never allowed to seed the mirrored store.
- Hydration is mutation-gated by bootstrap metadata and expected entity counts,
  then performs tombstone reconciliation. Active behavior consistently uses
  `activeMeanings` so tombstoned meanings cannot participate in prompts,
  grading, correction, mastery, cards, search, speech, snapshots or UI.
- Attempts remain append-only learning facts. Logical duplicates are resolved
  deterministically, conflicting payloads fail hydration without applying
  either fact, and canonical `(answeredAt, id)` replay deterministically
  rebuilds ReviewState and meaning success days.
- Migration compatibility is covered by a production-shape nine-model V1
  SQLite fixture migrated through the production schema plan, including
  relationship/default verification and post-migration save/reopen behavior.
- This is not an approval of the complete CloudKit feature or production
  cross-device behavior. The code-level approval is bounded by the verification
  below; actual CloudKit opt-in execution and real-device bidirectional
  propagation remain pending acceptance evidence.

## Awaiting-Bootstrap-Metadata Improvement (2026-07-15)

### Review Sequence

- The loop ran sequentially as Director diagnosis -> Executor change -> Monitor
  review. The Monitor issued `REJECT` because claim completion crossed neither
  a proven CloudKit export boundary nor a durable transaction boundary, and a
  same-request resume could rely on a no-op save that produced no export.
- The Director issued revised constraints, the same Executor implemented the
  correction, and the Monitor issued a code-level `APPROVE` after re-review.
  This approval covers the implementation and deterministic tests only, not
  real-device CloudKit export/import behavior.

### Accepted Decision

- Mac may transition the fixed server claim from `seeding` to `completed` only
  after a successful CloudKit export is observed for the receipt/probe
  transaction belonging to the same store, request and source fingerprint.
- The export observer is registered before the seed or probe save so a fast
  export cannot occur outside the observation window. Export errors, timeout,
  mismatched identity or an unproven transaction boundary fail closed and keep
  the claim in `seeding`.
- Schema V3 adds `BootstrapExportReceipt`. The receipt persists request ID,
  source fingerprint, persistent-store UUID, transaction commit boundary,
  probe generation, state and nonce in the mirrored store.
- Initial seed data and its receipt are committed together. A `seeding` resume
  must update generation and nonce and save a durable probe transaction; a
  no-op save is not accepted as export evidence. Only a matching successful
  export at or after the active receipt boundary permits claim completion.
- iOS remains non-seeding and mutation-gated while awaiting metadata. Its
  diagnostics now combine local hydration, CloudKit account and fixed-claim
  state; they distinguish missing claim, Mac upload in progress and completed
  claim with delayed metadata. Manual refresh, successful-import refresh and
  foreground-only polling re-evaluate the state without background polling.

## Claim Recovery And Canonical Fingerprint Follow-Up (2026-07-15)

### Diagnosis And Review

- The Director traced the reported claim rejection, persistent iOS waiting,
  full snapshot recovery upload and truncated macOS Settings status together.
  The bootstrap fingerprint mixed canonical domain facts with volatile merge
  metadata and replay-derived state, so the same logical dataset could fail
  tuple recovery or trigger an unnecessary full snapshot upload.
- The Executor implemented recovery persistence, canonical comparison and
  Settings layout changes. The Monitor issued one `REJECT` because the first
  canonical fingerprint still included replay-derived `Word.statusRaw` and
  `Meaning.successDays`. After those fields were excluded with ReviewState and
  regression coverage was added, the Monitor issued a code-level `APPROVE`.

### Accepted Decision

- The pending bootstrap claim tuple and originating device identity are stored
  in Keychain. Legacy UserDefaults values are removed only after a successful
  Keychain migration. An Application Support recovery manifest binds the
  checkpoint path, canonical fingerprint and complete claim tuple.
- Settings fetches and displays the fixed server claim before creating a new
  token. Matching Keychain state resumes normally. If local tuple state was
  lost, recovery from the server tuple additionally requires matching current
  or checkpoint canonical fingerprint, schema version and persisted export
  receipt. Foreign ownership or any mismatch fails closed without claim
  deletion, takeover or replacement.
- A server claim already in `completed` is verification-only: matching content
  returns without importing or reseeding. Completed state never authorizes a
  fresh seed, and foreign tuples remain denied.
- The bootstrap/recovery fingerprint is canonical-domain-only. It excludes
  export time, sync metadata, reconciliation and receipt/probe bookkeeping,
  per-record merge metadata, and the replay-derived `Word.statusRaw`,
  `Meaning.successDays` and ReviewState. Stable IDs, source content,
  relationships, Attempts, tombstones and delete state remain covered.
- Manual snapshot recovery compares canonical fingerprints first. Equal
  content reports no change and skips the asset write; differing content uses
  a conditional full snapshot upload and aborts if server metadata changes
  between inspection and save.
- macOS Settings uses a resizable minimum/ideal window. Long claim/status text
  is unbounded and selectable, and action groups adapt vertically when the
  available width would otherwise truncate diagnostics.

## Remaining Work

- Run the opt-in CloudKit integration path with
  `VOCAB_RUN_CLOUDKIT_INTEGRATION=1` against the intended private CloudKit
  environment; it was skipped in the recorded 155-pass run.
- Run real iPhone smoke tests with the same iCloud account as the signed Mac.
- Confirm production CloudKit schema deployment and legacy array-property
  behavior under real per-record mirroring. To-many relationships are optional
  for CloudKit compatibility; simulator builds do not prove propagation timing.
- Verify cross-device flows: Mac set creation appears on iPhone, iPhone test
  attempts appear on Mac, and Mac meaning edits appear on iPhone.
- Verify tombstone propagation and ReviewState replay after offline concurrent
  edits on two signed devices before relying on cleanup of old tombstones.
- Observe the V3 receipt/probe export boundary and subsequent mirrored import
  on a real signed Mac and iPhone using the same private CloudKit account.
- Exercise Keychain/manifest tuple recovery and canonical snapshot skip against
  that real private CloudKit environment; simulator and fake-service coverage
  do not establish actual export/import behavior.
- Do not record full feature approval until the opt-in CloudKit run and
  real-device bidirectional propagation checks have passed.

## Verification

- Focused suites cover hydration gate, idempotent tombstone reconciliation,
  deleted meanings, out-of-order replay, mirrored compaction, persistent store
  reopen, snapshot v2 roundtrip, v1 mirrored rejection, fallback prohibition,
  and automatic snapshot prohibition.
- Fourth-pass focused XCTest: 35 passed, 0 failures
  (`/tmp/VocabFourthFocused`). This includes the exact legacy fixture and all
  claim state/failure-injection cases in addition to hydration, reconciliation,
  snapshot and automatic-snapshot prohibition coverage.
- The first `exit 65` was Swift overlapping-access errors while assigning a
  snapshot fingerprint; computing the fingerprint before mutation fixed it.
- Fourth-pass final full macOS XCTest: 155 passed, 3 skips, 0 failures
  (`/tmp/VocabFourthFinalMacTests`). Two skips are performance gates and one is
  the opt-in CloudKit integration test.
- Generic iOS Simulator Debug build passed with signing disabled
  (`/tmp/VocabFourthFinalIOS`). No device signing, install or propagation test
  was attempted.
- Signed Mac Debug build passed (`/tmp/VocabFourthFinalSignedMac`) using an
  Apple Development identity. `codesign --verify --deep --strict` passed. The
  embedded entitlement dump and generated `.xcent` both contain
  `iCloud.com.swainyun.Vocab` and the `CloudKit` service.
- Awaiting-bootstrap-metadata final macOS XCTest: 163 passed, 3 skips, 0
  failures (`/tmp/VocabReceiptFinalFullMac`). The skipped cases include the
  opt-in CloudKit integration path; deterministic receipt/export-gate coverage
  passed without replacing real CloudKit observation.
- Awaiting-bootstrap-metadata iOS Simulator build passed with signing disabled.
  This proves compilation, not real-device CloudKit export/import propagation.
- Claim-recovery/canonical-fingerprint final macOS XCTest: 175 passed, 3 skips,
  0 failures (`/tmp/VocabMinimalReworkFull-20260715.xcresult`). The skips were
  two performance gates and the opt-in CloudKit integration test.
- Claim-recovery/canonical-fingerprint iOS Simulator build passed with signing
  disabled (`/tmp/VocabMinimalReworkIOS`). Real-device CloudKit behavior was
  not exercised.

- `git diff --check`
- `./script/verify_changed.sh Vocab/App/VocabModelContainerFactory.swift VocabTests/App/VocabModelContainerFactoryTests.swift Docs/PerRecordCloudKitMirroringPlan.md`
- `xcodebuild -project Vocab.xcodeproj -scheme VocabIOS -configuration Debug -derivedDataPath /tmp/vocab-ios-mirroring-plan-build -destination generic/platform=iOS\ Simulator CODE_SIGNING_ALLOWED=NO build`
- `./script/verify_changed.sh Vocab/App/VocabSyncSnapshot.swift VocabTests/App/VocabSyncSnapshotTests.swift Vocab/App/VocabLocalStoreCheckpoint.swift VocabTests/App/VocabLocalStoreCheckpointTests.swift Vocab/App/VocabApp.swift VocabIOS/App/VocabIOSApp.swift Vocab/Presentation/RootView.swift VocabIOS/Presentation/VocabIOSRootView.swift`
- `xcodebuild -project Vocab.xcodeproj -scheme VocabIOS -configuration Debug -derivedDataPath /tmp/vocab-ios-mirroring-final-build -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

## Relationships

This supersedes the out-of-scope per-record mirroring note in `CL-0014` for
future migration work. `CL-0014` remains active for snapshot batch sync until
per-record mirroring is fully enabled and verified.
