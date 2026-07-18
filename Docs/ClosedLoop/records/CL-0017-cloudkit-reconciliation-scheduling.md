# CL-0017: CloudKit Reconciliation Scheduling

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-15 (Asia/Seoul) |
| Scope | macOS/iOS CloudKit remote-change handling, hydration polling, SwiftData reconciliation concurrency and write minimization |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while per-record CloudKit reconciliation and hydration scheduling exist |

## Decision

- A CloudKit remote-change notification must not run a full reconciliation when
  hydration is already `ready`. Full reconciliation is limited to the initial
  `reconciling` transition and a successful CloudKit import.
- macOS remote-change handling uses debounce and single-flight coalescing so a
  burst cannot recursively run `remote-change -> reconcile -> save ->
  remote-change`.
- iOS bootstrap polling is foreground-only and bounded to delays of 5, 10, 20,
  40 and 60 seconds. It stops at `ready`, `failed`, cancellation or background
  transition instead of polling indefinitely.
- Concurrent refresh reasons are queued and coalesced. A successful-import
  reason is never discarded by an in-flight manual or polling refresh and
  causes exactly one follow-up reconciliation.
- Heavy SwiftData reconciliation runs through a reusable `ModelActor` created
  on a utility execution path. SwiftData objects and `ModelContext` remain
  actor-confined; only `Sendable` state values cross back to UI code.
- Attempts are grouped by word before derived-state calculation, keeping the
  reconciliation pass at `O(words + attempts)` rather than
  `O(words * attempts)`.
- Expected review state is calculated before mutation. Setters and
  `ModelContext.save()` run only for changed values; metadata timestamps are
  not refreshed merely because a status check occurred.

## Review Outcome

The first Monitor review rejected the implementation for three reasons:

1. iOS could discard a successful-import event while another refresh was in
   flight.
2. Creating the reconciliation worker from UI-isolated code did not adequately
   demonstrate non-main execution and actor confinement.
3. Reassigning every word before comparison could create unnecessary SwiftData
   changes and CloudKit exports.

The Executor added reason coalescing, utility-created reusable actor workers,
actor-confined contexts, changed-only mutation and focused concurrency/write
tests. The Monitor then found no remaining P1/P2 issue and issued `APPROVE`.

## Cause And Evidence

The macOS hang was caused by every remote-change notification invoking a full
`ready` reconciliation, which always updated metadata and saved, producing
another remote-change notification. Reconciliation also fetched and rebuilt
large parts of the store on the UI actor. iOS repeated equivalent heavy work
from an unbounded polling loop whose termination state was checked only before
entering the loop.

Focused verification completed:

- `VocabCloudReconciliationTests`: 14 passed, including concurrent import
  reason coalescing, worker isolation, changed-word isolation and UI heartbeat.
- `LearningCoordinatorTests`: passed; existing opt-in performance cases were
  skipped by their normal configuration.
- macOS `Vocab` build: passed.
- iOS `VocabIOS` build: passed.

The UI heartbeat fixture uses 1,000 words and verifies this concurrency
regression below 100 ms. It is not a substitute for the separate 10,000-word
full-reconciliation performance acceptance measurement.

## Retention

This compact decision is protected while the synchronization behavior exists
because it explains correctness and UI responsiveness constraints. Raw agent
transcripts, process samples and build logs are intentionally not retained.
Archive or deletion requires the normal reviewed index update defined by
`CL-0002`.

This decision extends `CL-0016`; it does not replace bootstrap migration,
receipt, tombstone or data-loss protections.
