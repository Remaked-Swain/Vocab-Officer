---
paths:
  - "Vocab/App/**"
  - "Vocab/Data/**"
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

- Never change bundle IDs (`com.swainyun.Vocab`, `.iOS`) or the container
  `iCloud.com.swainyun.Vocab`; reinstall by overwriting, never by deleting.
- Activation requires: account available, build allows CloudKit runtime,
  signed entitlement, verified/migrated schema, and a checkpoint
  (`Vocab.store`, `-wal`, `-shm`, `manifest.json`) or explicit user
  confirmation. Otherwise stay local and show the blocker in natural language.
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
    records request a deferred full audit. The cursor is read before a pass or audit writes
  anything and saved only after it succeeds. Full audits run only while
  inactive/backgrounded; returning active cancels cooperative maintenance.
  Indexes, receipts and the cursor are written only after success.
  Maintenance tasks use generation ownership.
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

## Open Items

- Per-record mirroring is code-level approved; real-device propagation is
  unverified (Mac edit → iPhone, iPhone test → Mac attempts/review, meaning
  edit, tombstones before destructive deletes). Real CloudKit open/close is
  opt-in via `VOCAB_RUN_CLOUDKIT_INTEGRATION=1`. Keep `localOnly` the default
  until signing, schema compatibility and first-device migration pass.
- History-based import reconciliation is test-verified only against local
  saves. Still unverified on real devices: that CloudKit import transactions
  appear in history as expected, and how much history CloudKit retains
  before a cursor goes stale.
- Undecided: array fields (`successDays`, aliases, `wordIDs`) under
  concurrent edits; whether memory-aid caches and anonymous aggregates stay
  mirrored; in-process container rebuild vs restart on store switch.
