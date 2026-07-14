# iCloud And iPhone Sync Plan

## Goal

Allow the user's iPhone to continue vocabulary study during travel while keeping
the existing macOS app and local vocabulary store recoverable.

## Non-Negotiable Safety Rules

- Keep the existing macOS bundle identifier stable: `com.swainyun.Vocab`.
- Do not delete or move the current local store during sync work.
- Keep `localOnly` as the default store mode until CloudKit entitlement,
  schema migration and first-device backup checks are complete.
- Use a separate branch for all iCloud/iOS work.
- Never require deleting the installed macOS app to test a new build.

## Storage Direction

The app now has a single store factory:

- `VocabModelContainerFactory.makeContainer(syncMode:)`
- `VocabSyncMode.localOnly`
- `VocabSyncMode.cloudKitPrivate`

`localOnly` preserves the current store location:

```text
~/Library/Application Support/Vocab/Vocab.store
```

`cloudKitPrivate` prepares the same model container for:

```text
iCloud.com.swainyun.Vocab
```

The CloudKit mode is intentionally not the default yet. Turning it on before
entitlements and schema compatibility are verified could put the production
macOS vocabulary store at unnecessary risk.

## iCloud Concern Review

| Concern | Decision |
| --- | --- |
| iCloud capacity | Vocabulary data is mostly text. Sync word records, meanings, sets, attempts, progress and memory-aid text. Do not sync PDFs, screenshots or generated audio assets. |
| Network and battery | The iPhone app must be offline-first. Tests, study cards and search use local SwiftData. iCloud sync runs opportunistically. |
| Sync speed | Treat CloudKit as eventual sync, not instant messaging. UI should show a last-known sync state and avoid promising immediate propagation. |
| Similar UX | Share domain/application logic, not desktop layout. iPhone UI should use large cards, one-hand actions and local search. |

## Required Implementation Phases

1. Preserve macOS behavior.
   - Keep `localOnly` default.
   - Verify Release build and installed app after each storage change.
   - Keep the runtime iCloud activation gate closed until every readiness
     condition passes.

2. Audit SwiftData model compatibility for CloudKit.
   - Check unique attributes, required relationships, arrays and delete rules.
   - If a property is not CloudKit-safe, migrate with an explicit compatibility
     plan before enabling sync by default.

3. Add signing assets.
   - Add iCloud capability entitlement.
   - Use one CloudKit container: `iCloud.com.swainyun.Vocab`.
   - Keep iOS bundle identifier stable after first device install.

4. Add iOS target after the shared storage layer is stable.
   - Reuse `Domain`, `Application`, `Data` and `Infrastructure`.
   - Add a small iOS-specific `@main` app and presentation layer.
   - Avoid including the macOS `VocabApp` entry point in the iOS target.
   - The first iOS target is intentionally explicit-source based. It includes
     the SwiftData records, normalizer, store factory and iCloud readiness
     services, but does not include macOS-only AppKit/OCR/settings views.

5. Enable migration and sync.
   - First launch with iCloud should keep the local store intact.
   - Existing local data should be uploaded only after a backup/export checkpoint
     or an explicit user confirmation.

6. Add user-facing sync status.
   - iCloud account availability.
   - Current mode: local-only or iCloud.
   - Last local write time.
   - Last observed sync issue in natural language.

## Activation Gate

The app must not allow iCloud activation just because a CloudKit account is
available. The readiness gate must pass all of these conditions:

- iCloud account state is available.
- The build explicitly allows CloudKit runtime activation.
- The signed app has the CloudKit entitlement for
  `iCloud.com.swainyun.Vocab`.
- The SwiftData schema is verified or migrated for CloudKit.
- The first upload of the existing local vocabulary store is backed up or
  explicitly confirmed by the user.

Until all conditions pass, Settings should show the blocker in natural language
and the app should continue using the local store.

Before the first upload flow opens, the app must create a checkpoint of the
local SwiftData store files:

- `Vocab.store`
- `Vocab.store-wal`, when present
- `Vocab.store-shm`, when present
- `manifest.json`, with the original path, copied file names and creation time

The checkpoint is a safety prerequisite only. It must not change the active
store path or delete any local vocabulary data.

## iOS Target Do-Not-Start Conditions

Do not add or ship an iOS target while any of these are true:

- The macOS local store cannot be restored after a failed CloudKit attempt.
- The CloudKit activation gate is still blocked by schema or entitlement
  readiness.
- The first-upload migration path does not prevent duplicate words, duplicate
  daily set items, or partial uploads.
- The iOS target would include the macOS `VocabApp` entry point or desktop-only
  presentation files.

## iPhone Companion Scope

The iPhone companion target is named `VocabIOS` and builds as
`com.swainyun.Vocab.iOS`. Its first scope is:

- Show synced daily sets newest-first.
- Show review words in a compact list.
- Provide a lightweight tap-to-reveal card test for commute use.
- Show the same iCloud readiness blockers as macOS Settings.

This target is not a replacement for the macOS authoring app. Bulk OCR intake,
large library maintenance and Gemini memory-aid management remain macOS-first
until the CloudKit migration is proven safe.

The iPhone target can build before sync is enabled, but it will only show the
phone-local store until the CloudKit activation gate is opened.

## Cloud Snapshot Transport

The first cross-device transport is an internal snapshot, not direct SwiftData
CloudKit mirroring. The app serializes words, meanings, review state and daily
set membership into one versioned JSON payload, stores it as a private CloudKit
asset, and lets the receiving device replace its local store from that snapshot.

This keeps the existing macOS store local-first while avoiding premature
migration of the production SwiftData schema into CloudKit. The upload/download
UI must stay behind the readiness gate and explicit user confirmation because a
phone restore intentionally replaces the phone-local Vocab store.

The entitlement files are present in the repository and wired to the macOS and
iOS app targets with automatic signing:

- `Vocab/Vocab.entitlements`
- `VocabIOS/VocabIOS.entitlements`

Xcode is expected to use automatic signing with the user's selected Apple
Developer team and to manage provisioning profiles automatically. Runtime UI
still checks whether the signed app actually carries the required CloudKit
container before enabling Mac upload or iPhone import, so a broken provisioning
state cannot expose a misleading sync action.

Command-line builds also depend on Xcode account state. If Apple updates the
developer agreement, automatic provisioning can fail until the agreement is
accepted in Xcode or the developer portal. After that, `xcodebuild
-allowProvisioningUpdates` can create or refresh the Mac Team Provisioning
Profile and sign the installed app with the CloudKit entitlement. SwiftData unit
tests should continue to use `CODE_SIGNING_ALLOWED=NO` when they only verify
local in-memory model behavior.

## Automatic Batch Bidirectional Sync Policy

Automatic iCloud sync is batch-based and snapshot-cursor driven. It is not
real-time record mirroring. The app keeps local SwiftData as the offline-first
store and uses CloudKit as an eventual transport when runtime conditions are
safe.

Automatic sync may run on app launch and foreground activation only after these
conditions pass:

- iCloud account is available.
- The signed app has the `iCloud.com.swainyun.Vocab` CloudKit entitlement.
- A previous manual upload or import created a shared baseline cursor.
- Network is available.
- Low Power Mode is off for non-user-initiated automatic sync.
- Constrained network mode is off for non-user-initiated automatic sync.

The first automatic implementation uses the existing snapshot transport as a
guarded batch. It stores compact metadata with a content fingerprint in the
CloudKit snapshot record and stores a local cursor after successful upload or
download. On the next automatic run:

- local changed, cloud unchanged from cursor: upload local snapshot.
- cloud changed, local unchanged from cursor: download cloud snapshot.
- both unchanged: skip.
- both changed from cursor: stop and report conflict; do not overwrite either
  side automatically.

This prevents the main data-loss case where an iPhone learning session and a
Mac authoring session both change data before sync. The current stage still
does not provide per-record merge, tombstone replay, CloudKit change-token
sync, or field-level conflict resolution. Those remain required before removing
the conflict stop or treating this as full live bidirectional sync.

The manual snapshot upload/import UI remains the fallback and recovery path.
It is also how the initial shared baseline is created.

This transport detects whether either side changed by comparing full-snapshot
content fingerprints against the last synced cursor. It does not compute or
send per-record diffs. Therefore it is appropriate as a safe baseline and
recovery transport, but it must not be described as efficient incremental sync.

The efficient final form is per-record mirroring or an explicit delta protocol:

- every mutable record needs a stable UUID and an app-managed `updatedAt`;
- deletes should sync as tombstones before any hard-delete cleanup;
- append-only learning events such as attempts should merge by record ID;
- derived summaries such as review state should be rebuildable from events or
  reconciled by a deterministic rule;
- concurrent edits must compare record IDs, timestamps and domain rules instead
  of replacing the whole store.

Until that exists, automatic batch sync must keep the current one-sided-change
rule and conflict stop.

## iOS Sync Status UI Policy

iPhone sync status must not be shown as a persistent banner on every tab. The
study, review and test tabs are primary learning surfaces; sync feedback should
not shift their content or compete with navigation titles.

The iOS app should expose durable sync state in the Settings tab. Only
action-required failures, conflicts or destructive confirmations should become
app-level interruptions. macOS can use a wider detail-area banner because its
sidebar/detail layout has more stable space, but that desktop placement should
not be copied to iPhone.

Any download or import path that destructively replaces a local SwiftData
store must first create a local store checkpoint and must stop before replace
or cursor advancement if checkpoint creation fails. This applies to iOS manual
import, iOS automatic download and macOS automatic download. Successful
download/import messages may include the checkpoint directory name so the user
can find the recovery copy.

## Developer Program Expiration Policy

Developer Program expiration should not erase the vocabulary database by itself.
The dangerous operations are:

- deleting the app instead of overwriting it,
- changing the bundle identifier,
- changing the CloudKit container,
- relying only on local storage with no cloud copy.

For personal sideloaded use, reinstall by overwriting the same bundle identifier.
If the app must be deleted, confirm that CloudKit sync has completed first.
