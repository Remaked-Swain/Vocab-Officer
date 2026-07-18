# CL-0019: Explicit Recovery and CloudKit Write Safety

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-18 (Asia/Seoul) |
| Scope | per-record CloudKit mirroring safety, `Vocab.store` recovery isolation, CloudKit mutation authorization and recovery-replica scheduling |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while mirrored-store recovery or CloudKit authoring exists |

## Decision

- Normal `.localOnly` startup always opens the mutable application-support
  `Vocab.store`. A published recovery generation can never shadow it or become
  an ordinary writable store.
- Recovery is explicit only. A selected generation is verified, copied into a
  staging store, validated, checkpointed and atomically swapped under a
  fail-closed journal. Interrupted or malformed swap state is resolved before
  opening the local store; unresolved state blocks launch rather than risking
  an unsafe open.
- CloudKit mutation authorization is bound to a non-persisted runtime
  validation epoch. A saved lease from an earlier process or foreground epoch
  cannot authorize changes. The current epoch requires a successful full
  audit before CloudKit-backed writes are re-enabled.
- Automatic `Vocab.store` recovery-replica refresh remains disabled. It may
  not be enabled until the 10,000-word / 200,000-attempt measurement proves
  that backup, verification and publication meet the agreed responsiveness
  and storage limits. This limitation is superseded by `CL-0020`, which allows
  automatic refresh only through foreground-safe, background-triggered guarded
  scheduling.

## Rationale

`VocabMirrored.store` is the active local SwiftData cache for per-record
CloudKit mirroring. `Vocab.store` remains an independent recovery/local-only
store; treating recovery generations as normal storage could silently expose
stale data. A persisted authorization lease also cannot establish that a
newly launched process has imported and audited remote changes.

## Evidence

- Monitor approved `RUN-20260718-SYNC-SAFETY-FIXES` after independently
  running 12 focused macOS tests covering recovery interruption, local-store
  isolation, mutation epochs and CloudKit reopen.
- `git diff --check` passed. The Executor also reported successful macOS and
  iOS Simulator builds.
- At the time of this record, the recovery scheduler flag remained
  `VocabRecoveryReplicaScheduler.automaticRefreshEnabled = false`; `CL-0020`
  supersedes that disabled-state limitation.

## Limitations

- No end-user recovery UI is exposed yet; the application-boundary recovery
  operation is intentionally not reachable as an automatic fallback.
- The automatic rolling `Vocab.store` recovery-replica disabled-state
  limitation is superseded by `CL-0020`.
- Real-device private-CloudKit bidirectional propagation remains separately
  pending under `CL-0016`.

## Relationship

This extends `CL-0016` and `CL-0017` without replacing their per-record
mirroring, migration, scheduling or reconciliation decisions. `CL-0020`
supersedes only this record's automatic recovery-replica disabled-state
limitation.
