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

5. Enable migration and sync.
   - First launch with iCloud should keep the local store intact.
   - Existing local data should be uploaded only after a backup/export checkpoint
     or an explicit user confirmation.

6. Add user-facing sync status.
   - iCloud account availability.
   - Current mode: local-only or iCloud.
   - Last local write time.
   - Last observed sync issue in natural language.

## Developer Program Expiration Policy

Developer Program expiration should not erase the vocabulary database by itself.
The dangerous operations are:

- deleting the app instead of overwriting it,
- changing the bundle identifier,
- changing the CloudKit container,
- relying only on local storage with no cloud copy.

For personal sideloaded use, reinstall by overwriting the same bundle identifier.
If the app must be deleted, confirm that CloudKit sync has completed first.
