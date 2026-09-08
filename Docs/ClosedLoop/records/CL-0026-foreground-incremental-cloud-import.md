# CL-0026: Foreground Incremental Cloud Import

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-09-03 (Asia/Seoul) |
| Scope | macOS/iOS foreground lifecycle, CloudKit import reconciliation, mutation continuity and deferred full audit |
| Agents | Codex main agent, one read-only Auditor |
| Partially supersedes | CL-0017, CL-0023 |
| Archive review | retain while per-record CloudKit synchronization exists |

## Problem

Returning to either app could trigger entity-wide count queries, complete
attempt/tombstone reconciliation, snapshot export, fingerprint generation and
mutation-authority invalidation. Although performed through a ModelActor,
those operations competed with UI queries for the same persistent store and
caused visible freezes.

## Decision

- Foreground activation never initiates hydration diagnostics or a full audit
  once the local mirrored store has previously reached a usable state.
- Cold launch reauthorizes a new runtime epoch from matching persisted
  lease/receipt and bootstrap metadata without scanning vocabulary entities.
- Generic remote-store notifications only mark potential work. Successful
  CloudKit imports are debounced and use the durable changed-identifier buffer
  plus import index to reconcile affected words and tombstones only.
- A successful import with no captured identifiers is unresolved evidence. It
  requests a durable deferred audit instead of assuming that nothing changed.
- A successful import does not revoke the existing validated mutation lease.
  Incremental reconciliation errors may still block unsafe writes through the
  existing error-to-authority policy.
- Missing, corrupt, unresolved, or version-incompatible incremental evidence
  requests a durable full audit but does not run that audit while the app is
  active. Pending identifiers are retained until successful processing.
- Requested or periodic full audits run only after the app becomes inactive or
  backgrounded. Returning active cancels cooperative maintenance work; a
  canceled maintenance audit preserves authority that was valid at its start,
  while a real audit error invalidates authority.
- A real integrity failure also invalidates the corresponding full-audit
  receipt, preventing stale evidence from reopening writes after relaunch.
- Cancellation and transient filesystem failures preserve previously valid
  offline authority; only reconciliation integrity errors revoke evidence.
- Maintenance tasks use generation ownership so a canceled task cannot clear
  or orphan a replacement task during rapid lifecycle transitions.
- First hydration and explicit manual diagnostics retain the complete safety
  checks needed to establish a usable mirrored store.
- Import indexes and audit receipts are written only after their corresponding
  reconciliation succeeds.
- A mutation check during the brief launch reauthorization window returns
  blocked without deleting the persisted lease needed for reauthorization.

## Performance Model

The normal import path is proportional to changed identifiers and attempts
attached to affected words. It does not enumerate the full vocabulary,
attempt history, tombstones, or export a full snapshot. Full linear work
remains available as deferred repair rather than foreground interaction work.

## Evidence

- Focused tests cover foreground diagnostic suppression, changed-ID
  incremental reconciliation without a full-audit receipt, deferred audit
  persistence, preservation of unresolved identifiers, cold-launch lease
  reauthorization, maintenance-audit authority preservation, and stale-receipt
  rejection after an audit failure.
- Existing reconciliation, authority, app build, and iOS build checks remain
  selected by `script/verify_changed.sh`.

## Limitations

SwiftData does not expose the underlying Core Data persistent-history token
API as a stable public interface. The implementation therefore uses the
existing durable ModelContext identifier buffer and versioned import index.
If identifiers cannot be resolved, it deliberately falls back to deferred
full audit rather than claiming incremental completeness.
