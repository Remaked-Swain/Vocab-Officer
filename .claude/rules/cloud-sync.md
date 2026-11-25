---
paths:
  - "Vocab/App/**"
  - "Vocab/Data/**"
  - "Vocab/Application/VocabMutationAuthority.swift"
  - "Vocab/Application/VocabHydrationStatus.swift"
  - "Vocab/Application/VocabBootstrapTokenStore.swift"
  - "Vocab/Application/VocabImportedChanges.swift"
  - "Vocab/Application/VocabImportHistory.swift"
  - "Vocab/Application/VocabFullAuditReceipt.swift"
  - "Vocab/Application/VocabCloudReconciler.swift"
  - "Vocab/Application/VocabCloudReconciliationWorker.swift"
  - "Vocab/Application/VocabRecordScrubbing.swift"
  - "VocabIOS/App/**"
  - "VocabTests/App/**"
  - "Vocab/*.entitlements"
  - "VocabIOS/*.entitlements"
---

# Persistence, CloudKit And Recovery

## Stores

- `VocabModelContainerFactory` is the single container boundary. Local mode
  opens `Vocab.store`; mirrored mode uses a separate `VocabMirrored.store`.
  Never open the local store directly as CloudKit-backed.
- macOS runs in the App Sandbox (`Vocab.entitlements`: sandbox, network
  client, user-selected read-only files, push). Its stores live in the app
  container; `Vocab/container-migration.plist` moves the pre-sandbox
  `Application Support/Vocab`, legacy `default.store*` and preferences in on
  the first sandboxed launch. Keep that manifest in sync with any new
  location outside `Application Support/Vocab`.
- Local→mirrored migration checkpoints first, preserves the local store, and
  never replaces a non-empty mirrored store. Older snapshot JSON missing newer
  collections decodes them as empty. Snapshot transport is explicit
  recovery/export only; mirrored mode never runs batch sync.
- Destructive replacement (import, download, recovery) requires a successful
  checkpoint first; on failure stop without advancing cursors.
- Recovery is explicit: verify generation → staging copy → validate →
  checkpoint → atomic swap under a fail-closed journal; unresolved swap state
  blocks launch. A recovery generation never shadows the writable store.
- Recovery-replica refresh runs only from inactive/background transitions,
  single-flight, off the UI path, only when CloudKit is ready and the store is
  usable; skip unchanged generations only if the target store still exists.

## Activation And Bootstrap

- Both platforms ship as one multiplatform App Store Connect record with the
  bundle ID `com.swainyun.Vocab` (iOS moved off `.iOS` in #9; data that
  existed only in the old iOS app is restored by iCloud sync, not migrated).
  Never change the bundle ID or the container `iCloud.com.swainyun.Vocab`
  again; reinstall by overwriting, never by deleting.
- Activation requires: account available, build allows CloudKit runtime,
  signed entitlement, verified/migrated schema, and a checkpoint
  (`Vocab.store`, `-wal`, `-shm`, `manifest.json`) or explicit user
  confirmation. Otherwise stay local and show the blocker in natural language.
- Sync is the default (#21). iOS opens the mirrored store; the Mac starts a
  new first upload at launch by itself unless the user turned off "iCloud
  동기화 자동 시작" (`automaticActivationDisabledKey`) or
  `VocabSyncWorkPolicy` defers `.firstUpload`. The upload locks editing,
  then asks once to restart. iPhone cannot strand learning records before
  that: it has no vocabulary and its writes stay blocked until audited.
- App-scheduled sync work asks `VocabSyncWorkPolicy` (pure) with live
  `VocabSyncEnvironment` conditions: incremental reconciliation always
  runs; full audits and recovery replicas wait for thermal pressure, Low
  Power Mode and low battery off charge; the first upload also waits for
  account, network, quota, Low Data Mode and expensive networks. A user's
  request overrides cost and power, never prerequisites or heat. Deferred
  work stays due for the next lifecycle trigger; CloudKit's own mirroring is
  scheduled by the system and not gated.
- Bootstrap claim: fixed non-deletable private record `VocabBootstrapClaim-v1`
  (`claimed`/`seeding`/`completed` + claim/request/device/fingerprint/schema
  tuple). Transitions are conditional on the exact tuple; same-tuple retries
  resume; foreign ownership fails closed with no deletion or takeover path.
  A local save is not upload proof: stay `seeding` until a matching export
  event. Existing V1/V2 stores migrate in place, never reset.

## Conflicts

- Attempts are append-only facts grouped by `(sessionID, questionIndex)`:
  identical duplicates keep the lowest UUID; differing payloads are an
  explicit conflict (neither applied, hydration reports it). Replay sorts by
  `(answeredAt, id)` and recomputes review summaries. Tombstones apply
  idempotently and always win for the same UUID. No last-writer-wins.

## Mutation Authority

- CloudKit-backed writes require the current non-persisted runtime epoch plus
  a persisted lease matching store identity, bootstrap UUID, schema version,
  non-empty fingerprint and reconciled timestamp. A saved lease alone never
  authorizes a new process. `contentFingerprint` is not a live equality gate.
- Foreground reentry does not rotate the epoch. Generic
  `NSPersistentStoreRemoteChange` does not revoke authority. Explicit
  invalidation and real integrity failures revoke authority and the audit
  receipt; cancellation and transient filesystem errors preserve it.
  Revocation fails closed: a receipt file that cannot be deleted is
  recorded as revoked in the lease defaults and never loads until a new
  audit writes a receipt at that path.
- `try?` in sync and persistence code is allowed only where `nil` takes the
  fail-closed path (no authority, no baseline, a conflict, a full audit, or
  "not exported yet") or for best-effort cleanup of temporary files. Each
  non-obvious site says which in a comment.
- Cold launch reauthorizes from matching lease/receipt metadata without
  scanning vocabulary; mutation checks during that window return blocked
  without deleting the lease.
- iOS may write learning facts (sessions, answers, completion) only when the
  mirrored store is ready and audited. Vocabulary authoring, including
  aliases, is Mac-only.

## Reconciliation

- Successful imports are debounced and reconcile only records changed in
  persistent history since the saved cursor (`VocabImportHistoryReader`,
  any author).
  - Word, meaning, attempt and tombstone changes are diffed against the
    import index.
  - A review-state or memory-aid change always marks its word affected.
  - Every changed record rechecks its own tombstone (same ID), so an older
    peer cannot resurrect retired content.
  - Only bootstrap metadata, export receipts, sessions and anonymous counts
    are ignored; none of them is derived or tombstoned per record.
  - A pass that changes nothing does not save, so reading back its own
    writes costs one pass with no writes.
  - No cursor, a cursor from another store, pruned history, a hard delete,
    an unknown model, an unresolvable record or more than 2,000 changed
    records request a deferred full audit.
  - The cursor is read before a pass or audit writes anything and saved
    only after it succeeds; indexes and receipts are likewise written only
    after success.
  - Full audits run only while inactive/backgrounded; returning active
    cancels cooperative maintenance. Maintenance tasks use generation
    ownership.
- macOS remote-change handling is debounced and single-flight; iOS bootstrap
  polling is foreground-only at 5/10/20/40/60 s and stops at
  ready/failed/cancel/background.
- Heavy work runs in a reusable `ModelActor`; only `Sendable` values cross to
  UI. Group attempts by word (`O(words + attempts)`); write only changed
  values. Tombstones apply after imports and deleted attempts are excluded
  from replay so older peers cannot resurrect retired content.
- XCTest mutation-lease `UserDefaults` use process-scoped suites.
- Root views receive store notifications only through
  `VocabStoreChangeMonitor`: observers run on the posting thread and yield
  `Sendable` events the views handle on the main actor; never `.onReceive`
  a store notification. Notifications only signal that something changed.
  Which records changed comes from persistent history, never from
  notification payloads.

## Status UI

iOS shows durable sync state in Settings only; interrupt only for
action-required failures, conflicts or destructive confirmations. The macOS
detail-area banner is not copied to iPhone.

A full iCloud quota (`VocabCloudQuotaClassifier`: direct, partial-failure and
wrapped errors) from mirroring events and from direct CloudKit writes (claim,
snapshot; reported through `VocabCloudQuotaStatus.report`, never the store
alone) is recorded device-locally with its detection time and keeps
local use on the current store; never delete, replace or reset a store
because of it. Both platforms alert once on the first transition; macOS also
shows a persistent detail-area banner, and both show it in Settings until a
real CloudKit export succeeds. "Recheck" writes the private
`VocabCloudHealthProbe` record; a writable probe alone never clears the
warning. The probe record type must exist in the Production schema.

## Pitfalls

- A no-op write (reassigning an unchanged value) leaves the context dirty;
  sorted `fetchOffset` pages are then evaluated in memory, so a real
  library's full audit never finished (a397c86).

## Open Items

- Per-record mirroring is code-level approved; real-device propagation is
  unverified (Mac edit → iPhone, iPhone test → Mac attempts/review, meaning
  edit, tombstones before destructive deletes). Real CloudKit open/close is
  opt-in via `VOCAB_RUN_CLOUDKIT_INTEGRATION=1`. Sync is now the default
  (#21); the two-device propagation check is #21's remaining acceptance step.
- History-based import reconciliation is test-verified only against local
  saves. Still unverified on real devices: that CloudKit import transactions
  appear in history as expected, and how much history CloudKit retains
  before a cursor goes stale.
- Undecided: array fields (`successDays`, aliases, `wordIDs`) under
  concurrent edits; whether memory-aid caches and anonymous aggregates stay
  mirrored; in-process container rebuild vs restart on store switch.
