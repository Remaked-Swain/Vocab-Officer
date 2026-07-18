# CL-0020: Foreground-Safe Recovery Replica Refresh

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-18 (Asia/Seoul) |
| Scope | foreground lifecycle safety, automatic `Vocab.store` recovery-replica refresh, CloudKit readiness guards and recovery publication skipping |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while automatic recovery-replica refresh or mirrored-store recovery exists |

## Decision

- Automatic `Vocab.store` recovery-replica refresh is enabled, but never runs
  from foreground `.active` return. Foreground return also does not cancel an
  existing background-safe refresh.
- Automatic refresh is scheduled only from inactive/background lifecycle
  transitions, where replica publication is not allowed to block visible UI.
- Refresh requires CloudKit to be ready, the local store to be usable and a
  recovery source to exist. It must fail closed rather than publish from an
  incomplete or unavailable store.
- Refresh remains single-flight. Concurrent lifecycle triggers coalesce behind
  the active refresh instead of creating parallel SwiftData or file work.
- Heavy refresh work remains actor/async work and must not be performed on the
  UI path.
- Unchanged-generation skip is allowed only when the target generation store
  still exists. If the store was lost, matching metadata is insufficient and a
  new recovery replica must be published.

## Performance Basis

The accepted responsiveness argument is calculation- and structure-based, not
a completed 200,000-attempt measurement. The UI-blocking risk is reduced by
removing foreground `.active` refresh start/cancel work entirely. Remaining
automatic triggers are background-safe, async and single-flight, so repeated
lifecycle notifications cannot multiply refresh cost. Unchanged skip avoids
copy/verify/publish work for an intact current generation; the generation-store
existence guard prevents that optimization from masking data loss.

## Evidence

- Monitor issued `APPROVE` for Issue #3 on branch
  `swain/qa-foreground-performance-completion`.
- Focused behavior covered foreground non-start/non-cancel behavior,
  inactive/background scheduling, CloudKit/ready/local-usable guards,
  single-flight behavior, unchanged skip and republish after generation-store
  loss.
- The skipped acceptance evidence remains explicit: 200,000-attempt real
  measurement and entitlement-dependent CloudKit tests were not run.

## Supersession

This record supersedes the `CL-0019` unresolved limitation that automatic
`Vocab.store` recovery-replica refresh remained disabled until large-dataset
evidence. The feature is now allowed only under the foreground-safe,
background-triggered, guarded and single-flight constraints above.

`CL-0019` remains active for explicit recovery, local-store isolation, atomic
swap safety and CloudKit mutation authorization. `CL-0016` remains the owner
for real-device private-CloudKit bidirectional propagation evidence.

## Limitations

- The 200,000-attempt performance measurement is still not observed.
- Entitlement-dependent real CloudKit tests remain skipped; real-device
  bidirectional propagation continues under `CL-0016`.
