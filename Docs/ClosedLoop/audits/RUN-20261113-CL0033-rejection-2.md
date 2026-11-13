# RUN-20261113-CL0033 Audit Rejection 2

## Decision

`reject`

## Findings

1. Future-registered words could still enter Mixed through promotion or active
   review candidate paths.
2. A backdated meaning expansion could move the SOT revision boundary backward
   and make historical correct attempts valid again.
3. Current UI and its save path still used the removed loose-word terminology.
4. The registration scaling regression was absent from the standard
   performance script.
5. An unignored `build-ios` verification directory remained in the worktree.

## Required Rework

- Build all active candidate categories from the session-date-eligible pool.
- Make existing-word revision timestamps strictly monotonic and reflect the
  actual mutation time.
- Use unified vocabulary terminology and `registerWords` in current UI.
- Add the scaling regression to the standard script and ignore/clean build
  output.
