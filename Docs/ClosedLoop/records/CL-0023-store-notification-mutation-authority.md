# CL-0023: Store Notification Mutation Authority

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-18 (Asia/Seoul) |
| Scope | iCloud/SwiftData store notifications, mutation authority continuity, metadata fingerprint handling |
| Agents | Director, Executor, Monitor, Recorder |
| Partially superseded by | CL-0026 for successful-import authority invalidation |
| Archive review | retain while CloudKit mutation authorization or SwiftData mirroring exists |

## Decision

- `metadata.contentFingerprint` is no longer used as a live mutation-lease
  equality gate. A local save, export or other benign store-notification path
  may change the current fingerprint without proving the active runtime lease
  is unsafe.
- Mutation permission remains gated by the current runtime epoch, persisted
  lease existence, store identity, bootstrap UUID, schema version, non-empty
  metadata fingerprint and a reconciled metadata timestamp.
- Generic `.NSPersistentStoreRemoteChange` is not a reason to invalidate
  mutation authority or the full-audit receipt. It may represent local
  SwiftData/CloudKit store churn and must not repeatedly force the user back
  through "sync integrity required" checks after ordinary editing or testing.
- `successfulImport` and explicit invalidation remain fail-closed. Imported
  external writes or deliberate authority resets still require revalidation
  before gated mutation resumes.

## Rationale

The previous gate treated normal metadata fingerprint movement as evidence
that CloudKit-backed writes were no longer safe. This revoked authority after
ordinary app activity, so a user could pass integrity validation, edit a word,
and immediately be blocked again before testing.

The corrected boundary separates a benign store-change notification from an
actual import or explicit invalidation event. This preserves data-loss
protection while removing the loop that made normal Mac/iOS learning flows
feel broken.

## Evidence

- Monitor approved the change set with no findings.
- Focused `AuthoringCapabilityTests` passed for metadata-fingerprint movement,
  remote-store-change non-invalidation, successful-import fail-closed behavior
  and explicit invalidation.
- Full `xcodebuild test` passed.
- `./script/verify_changed.sh` passed.

## Limitations

- Presentation notification handlers are covered through policy/runtime unit
  tests, not by a rendered SwiftUI notification integration fixture.
- Real-device private-CloudKit propagation evidence remains pending under
  `CL-0016`.

## Relationship

This record extends `CL-0016`, `CL-0019`, `CL-0021` and `CL-0022` without
replacing them. It narrows mutation-authority invalidation for generic store
notifications only. It does not weaken fail-closed handling for successful
CloudKit imports, explicit invalidation, store identity changes, bootstrap
changes, schema mismatches or new runtime validation epochs.
