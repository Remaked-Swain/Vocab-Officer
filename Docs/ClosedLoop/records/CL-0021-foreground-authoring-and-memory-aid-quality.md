# CL-0021: Foreground Authoring and Memory-Aid Quality

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-07-18 (Asia/Seoul) |
| Scope | macOS foreground authoring, mutation authority validation, MemoryAid/Gemini response quality |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while CloudKit authoring authorization or MemoryAid generation exists |

## Decision

- macOS foreground reentry alone does not invalidate mutation authority
  validation epoch or the active lease. A Mac user may continue standalone word
  editing after returning to the app without launching iOS solely to refresh
  authorization.
- `remoteStoreChange`, `successfulImport` and explicit invalidation still
  fail closed. Those events revoke mutation authority and require a fresh
  validation path before CloudKit-backed writes are authorized again.
- A saved lease is never enough to authorize a new process or a new validation
  epoch. Persisted lease state may support continuity only after the current
  runtime validation rules are satisfied.
- MemoryAid generation now uses prompt version `v4`, `maxOutputTokens` 850,
  strengthened primary and repair prompts and a stricter `QualityGate`.
  Existing `v3` cache entries are naturally avoided by the prompt-version
  change.

## Rationale

Foreground reentry is a normal macOS lifecycle event, not evidence that remote
state changed or that local authoring became unsafe. Treating it as an
authority reset forced unnecessary iOS app launches for Mac-only editing.
The fail-closed boundary remains tied to actual remote/import/invalidation
signals and process/epoch validation safety.

MemoryAid answers were too easy to accept when short, generic or poorly
structured. Raising output budget and quality checks makes generated memory
helps more useful while preserving repair fallback.

## Evidence

- Monitor issued `APPROVE` on branch
  `swain/offline-mac-editing-memory-aid-quality`.
- Focused tests passed for foreground authoring continuity, remote/import
  fail-closed invalidation, persisted lease safety and MemoryAid prompt/repair
  quality behavior.

## Limitations

- No issue number exists for this work yet.
- Real-device private-CloudKit propagation remains separately pending under
  `CL-0016`.
- MemoryAid quality is improved by prompts, token budget and gating, but final
  usefulness still depends on model behavior.

## Relationship

This record extends `CL-0019` and `CL-0016` without replacing them. It relaxes
only foreground reentry handling for macOS authoring. It does not weaken
`CL-0019` remote/import fail-closed mutation authorization or its rule that a
persisted lease alone cannot authorize a new process or validation epoch.
It also does not replace `CL-0016` per-record CloudKit mirroring safety and
real-device propagation evidence requirements.
