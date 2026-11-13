# RUN-20261113-CL0033 Audit Rejection 1

## Decision

`reject`

## Findings

1. Mastered reactivation after meaning expansion was not durable because
   attempt replay could restore the previous Mastered evidence.
2. Mixed-mode broad rotation could admit words registered after the requested
   session day.
3. Legacy set/loose presentation and contract language remained visible after
   the product moved to one vocabulary.
4. Registration performed repeated unindexed lookup work and presentation
   recomputed registration-day grouping more than once per render.

## Required Rework

- Bound mastery evidence to the latest SOT revision.
- Exclude future registration days from historical session generation.
- Keep legacy entities only as persistence compatibility details.
- Use one predictable library scan and one grouping pass per render.
