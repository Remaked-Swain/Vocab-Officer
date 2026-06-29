# CL-0013: Review Grid Cards

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-06-28 (Asia/Seoul) |
| Scope | `Vocab/Presentation/LibraryViews.swift` and review UI |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while the review UI exists |

## Decision

- The review tab presents entries in a `LazyVGrid` with adaptive columns using
  a minimum width of 210 points and 16-point spacing. Lazy rendering is
  retained for larger review collections.
- Every static card simultaneously displays the English source, the complete
  Korean meaning, the check state and priority. Cards have no toggle or other
  interaction.
- Complete meanings wrap instead of being truncated, and each card exposes an
  accessibility label containing its displayed review information.
- The `ReviewView` outer group uses 28-point padding, matching
  `StudyCardsView`, so grid cells and scroll indicators do not touch the
  detail-view boundaries.
- Existing priority ordering and filtering behavior remain unchanged.
- Symbols used by the cards remain compatible with macOS 14.

## Review And Verification

The Monitor rejected the implementation once, then approved the corrected
review-grid diff with no remaining blocking finding. The selected scoped build
for `Vocab/Presentation/LibraryViews.swift` and review UI completed
successfully. The Monitor also approved the Debug build and diff check for the
outer-padding correction.

## Limitation

This decision changes review presentation only. It does not change review
eligibility, scheduling, priority calculation or persistence.

## Relationships

This decision preserves the review scheduling and filtering contracts in
`CL-0006` and the previous-set review selection contract in `CL-0009`.
