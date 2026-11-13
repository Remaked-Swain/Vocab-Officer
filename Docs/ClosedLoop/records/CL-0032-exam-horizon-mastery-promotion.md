# CL-0032: Exam-Horizon Mastery Promotion

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-11-13 (Asia/Seoul) |
| Scope | Mastered promotion, maintenance, Mixed composition, performance verification |
| Review | Main implementation and single read-only Auditor |
| Archive review | retain while test scheduling or Mastered lifecycle exists |

## Problem

The vocabulary population is effectively unbounded while the examination is
about four months away. Requiring three successful Seoul dates for every word
made promotion throughput too low: broad fair rotation prevented most words
from receiving their second and third evidence dates. Conversely, permanent
exclusion after a small number of successes would mistake observed recall for
proof that a word can never be forgotten.

## Evidence Boundary

Retrieval practice and spacing improve durable vocabulary retention, and longer
absolute spacing generally improves long-term retention. The evidence supports
spaced successful recall, corrective feedback and later revalidation; it does
not provide a universal per-person probability threshold that this app can
truthfully claim without calibration data.

Relevant research includes Pavlik and Anderson (2005), DOI
`10.1207/s15516709cog0000_14`; Karpicke and Roediger (2007), DOI
`10.1037/0278-7393.33.4.704`; Karpicke and Bauernschmidt (2011), DOI
`10.1037/a0023436`; and Carpenter, Pan and Butler (2022), DOI
`10.1038/s44159-022-00089-1`.

Therefore, Vocab uses mathematically explicit, observable evidence counts and
due-date transitions. `Mastered` is an operational exclusion from routine
testing, not a claim of permanent memory or a deletion state.

## Decision

### Evidence states

- A final correct answer contributes at most one success event per Seoul date,
  regardless of mode, direction or typed/multiple-choice format.
- Success evidence on or before the latest wrong/unknown Seoul date is not used
  for subsequent promotion.
- Zero eligible success dates remains Active. One eligible success date becomes
  promotion-due on the next Seoul date. Two eligible success dates promote the
  word to Mastered.
- A wrong or unknown answer to a Mastered maintenance question immediately
  demotes the word to Active. It must earn two new success dates after that
  failure to return to Mastered.

For success-date set `S`, latest failure day `F`, and current day `D`, eligible
evidence is `E = {s in S | F is absent or s > F}`. Promotion is satisfied when
`|E| >= 2`. Promotion follow-up is due when `|E| = 1` and `max(E) < D`.

### Maintenance horizon

- Mastered words are excluded from ordinary active and broad rotation.
- Their next maintenance interval is 7 days at two verified dates, 14 days at
  three, 30 days at four, and 45 days at five or more.
- The 45-day cap guarantees at least two further opportunities inside a
  four-month exam horizon without allowing maintenance to dominate new words.
- Mixed admits at most two due Mastered words; Review admits at most four.

### Mixed mode

The 20-question target is capped by category: up to six promotion-due words,
up to four active-review words, up to two due Mastered words, and at least eight
broad-rotation words when the pool is sufficient. Overlapping words count
against every applicable cap. Lower lifetime exposure and older presentation
remain the fairness keys, and same-day unseen words remain preferred.

This replaces the fixed latest-set quota in Mixed. Recently registered words
still participate through broad rotation, but cannot repeatedly displace less
exposed vocabulary merely because their registration date is newer.

## Complexity And Fixture Policy

Session generation reads summary state rather than replaying attempts. Building
promotion and maintenance candidates is `O(W * M)` for `W` candidate words and
their small active-meaning collections, with `O(W log W)` ordering and `O(W)`
auxiliary lookup space. Attempt count does not enter the hot-path complexity.

Fixture performance tests are not mandatory for every policy constant or pure
decision change. They are required when a change alters query shape, index use,
cache lifetime, persistence schema, or asymptotic candidate selection. In that
case, focused Release microbenchmarks use the current production word count,
approximately 2x, and approximately 4x. Unrelated full-suite or huge-fixture
runs are prohibited because they add cost without increasing confidence.

## Verification

- Focused `StudyPoliciesTests` and `LearningCoordinatorTests`: passed.
- Same-day repeated success cannot promote a word: passed.
- First success becomes promotion-due only on a later Seoul date: passed.
- Evidence before the latest failure is ignored: passed.
- Two post-failure dates restore Mastered: passed.
- Maintenance intervals and Mixed/Review caps: passed.
- Four Mixed sessions retain 80-word fair rotation with sufficient candidates:
  passed.
- Promotion-due evidence bypasses the lifetime exposure floor and is selected
  even while unseen broad candidates remain: passed after Auditor rework.
- Maintenance intervals count only success dates after the latest failure:
  passed after Auditor rework.
- Swift style and whitespace checks: passed.

## Auditor Rework

The first Auditor review rejected promotion starvation, maintenance counting
pre-failure evidence, missing coordinator-level regressions and stale
architecture documentation. Rework lets the bounded promotion queue bypass the
broad rotation floor, derives maintenance intervals from eligible post-failure
evidence, adds both integration regressions and aligns `Docs/Architecture.md`.
The second review found an unused `SessionPolicy` wrapper that still equated
same-day registration with promotion evidence. It was removed; the shared
`MixedSessionCompositionPolicy` is now the single pure-domain composition rule.

## Relationships

- Preserves `CL-0006` same-day active-priority relief.
- Preserves `CL-0024` format-independent final judgement.
- Partially supersedes `CL-0031` three-date promotion, 14/30/60/120 maintenance
  ladder, and latest-reference-set Mixed quota.
- Preserves `CL-0031` lifetime exposure fairness and same-day unseen priority.
