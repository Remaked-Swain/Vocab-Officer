# CL-0022: iOS Learning Facts Offline Authority

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-18 (Asia/Seoul) |
| Scope | iOS mirrored-store learning facts, Mac-only vocabulary authoring, foreground validation epoch handling, alias correction behavior and mutation-lease test isolation |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while iOS learning sessions or CloudKit mutation authorization exist |

## Decision

- iOS may locally write learning facts while the Mac is off when the mirrored
  store is both ready and audited. This includes test-session creation, answer
  submission and session-completion facts.
- Vocabulary authoring remains Mac-only. iOS must not create or edit words,
  meanings, daily-set vocabulary content or other authoring-owned records.
- iOS foreground reentry does not rotate the validation epoch by itself.
  Remote-store changes, successful imports and explicit invalidation remain
  the events that force revalidation before gated mutation resumes.
- iOS direct alias addition is removed. iOS may record a one-time correction
  result only; durable alias authoring remains under Mac-owned vocabulary
  authoring.
- XCTest mutation-lease `UserDefaults` state must use process-scoped suites so
  lease evidence cannot leak between test processes or unrelated focused
  runs.

## Rationale

A ready, audited mirrored store already represents the local CloudKit cache
boundary required for append-only learning facts. Blocking those facts when
the Mac is powered off would make iOS unusable for normal study, even though
the writes are not vocabulary authoring and can be replayed as learning
history.

The narrower permission keeps the existing safety model intact. Mac remains
the only vocabulary-authoring device, while iOS contributes session and
attempt facts after readiness and audit checks. Foreground return is a normal
lifecycle event, not proof of remote divergence, so it must not revoke an
otherwise valid iOS epoch without an actual import, remote-change or explicit
invalidation signal.

## Evidence

- The implementation decision was accepted for the current change set.
- Verification was required to cover iOS learning-fact writes against a
  ready/audited mirrored store, Mac-only authoring boundaries, iOS foreground
  epoch continuity, one-time correction behavior and process-scoped
  `UserDefaults` mutation-lease isolation.

## Limitations

- Real-device private-CloudKit propagation evidence remains pending under
  `CL-0016`.
- This record does not authorize iOS vocabulary authoring or direct alias
  creation.
- This record does not weaken fail-closed behavior after remote-store change,
  successful import or explicit mutation-authority invalidation.

## Relationship

This record extends `CL-0016`, `CL-0019`, `CL-0020` and `CL-0021` without
replacing them. It uses `CL-0016` mirrored-store readiness as the prerequisite
for iOS local learning-fact writes. It preserves `CL-0019` mutation-lease and
validation-epoch fail-closed rules, with the narrower clarification that iOS
foreground reentry alone does not rotate the epoch. It remains compatible
with `CL-0020` foreground-safe lifecycle constraints and generalizes
`CL-0021` foreground-authority continuity to iOS learning facts only, while
keeping vocabulary authoring Mac-only.
