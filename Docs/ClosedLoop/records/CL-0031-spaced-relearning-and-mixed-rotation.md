# CL-0031: Spaced Relearning And Mixed Rotation

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-11-09 (Asia/Seoul) |
| Scope | review relief, Mastered qualification and maintenance, Mixed session rotation |
| Review | Main implementation and single read-only Auditor |
| Archive review | retain while test scheduling or Mastered lifecycle exists |

## Problem

Same-day testing is useful for recovering a failed word, but repeated success in
one short practice period is weaker evidence of durable recall than success
across separate days. Mixed sessions also overemphasized a small high-priority
review group and could starve older tested words even though users choose Mixed
specifically for broad coverage.

## Evidence

- Retrieval practice improves long-term retention more than repeated study, but
  durable learning depends on repeated retrieval rather than one successful
  exposure: Karpicke and Roediger (2008), DOI `10.1126/science.1152408`.
- Vocabulary retention benefits from spacing, and the benefit increases for
  longer retention intervals: Pavlik and Anderson (2005), DOI
  `10.1207/s15516709cog0000_14`.
- Successive relearning is strongest when successful recalls are distributed
  across sessions rather than massed into one session: Rawson and Dunlosky
  (2022), DOI `10.1177/09637214221100484`.

These findings support separate short-term relief and long-term mastery signals.
They do not justify treating an exact schedule as universal, so the interval
ladder remains a product policy that can be tuned without changing persistence.

## Decision

### Same-day relearning

- Final correct outcomes continue to build direction streaks. Every two
  English-to-Korean correct outcomes can reduce `activePriority` by one on the
  same day, preserving the practical recovery loop from `CL-0006`.
- A Seoul date is stored only once in mastery evidence. Repeated success on the
  same date can clear active review pressure but cannot produce Mastered status.
- After a final wrong or unknown outcome, only success dates strictly later
  than that Seoul date count. Three such dates are required to regain Mastered.
  Historical success before the failure is not reused.

### Mastered maintenance

- The next maintenance interval is derived from verified success-day count:
  three or fewer days use 14 days, four use 30, five use 60, and six or more use
  120 days.
- Review includes at most four due Mastered words. Mixed includes at most two,
  leaving most of the session available for active vocabulary rotation.
- Due Mastered words are ordered by earliest due date, then lower presentation
  count and older presentation time. In Mixed, words not shown earlier on the
  current Seoul day are ordered before already shown words.
- A final wrong or unknown maintenance answer immediately returns the word to
  Active and starts a new three-day relearning sequence.

### Mode composition

- Today keeps the latest reference set primary and includes loose words only as
  bounded supplementation.
- Selected Set remains strictly scoped to the chosen set.
- Loose remains strictly scoped to words without set membership.
- Review keeps up to 14 active failure-based candidates. Due Mastered
  maintenance can reserve up to four questions; previous-set recurrence uses
  the remaining capacity and still reaches six when maintenance is absent.
- Mixed caps reference-set questions at six, active-review questions at four
  and due Mastered maintenance questions at two. Multi-category words count
  against every applicable cap, so fallback cannot bypass a cap. Historical
  sets and loose words fill the remaining capacity, normally at least eight
  questions. If that broad pool is too small, the session is reduced instead
  of repeating capped categories. Broad candidates use lower lifetime exposure
  and older presentation time.
- The user's normal three-to-four Mixed sessions per day are treated as one
  daily rotation. A word already presented on that Seoul day is ineligible
  while any unseen eligible active or due-maintenance word remains. With at
  least 80 eligible words, four sessions therefore produce 80 unique words.
- Rotation also survives a date boundary. Reference-set, active-review and
  historical category quotas may select only words at the library's current
  minimum lifetime presentation count. A word presented yesterday therefore
  cannot take a quota from a less-presented word today; ties prefer the oldest
  `lastPresentedAt`. This adaptive full-library cycle is stronger than a fixed
  multi-day cooldown for libraries whose size can exceed 10,000 words.
- Future-dated sets are excluded from both historical and global fallback
  pools. Presentation summaries enforce these rules without scanning full
  attempt history.

## Compatibility And Performance

No SwiftData or CloudKit schema changes are introduced. The policy reuses
`successDays`, `latestWrongAt`, `lastTestedAt`, `presentationCount` and
`lastPresentedAt`. Candidate construction remains linear and ordering remains
`O(n log n)` over the relevant active or Mastered pool. No full attempt-history
scan is added to session generation.

The set-membership index is cached until a set-membership mutation invalidates
it. Active/Mastered candidate caches are invalidated separately when progress
or SOT edits change status, avoiding unrelated relationship reconstruction.
Sort keys are snapshotted before comparison to avoid repeated SwiftData access.
The Release fixture with 10,000 words and 10,000 existing sessions passes the
`p95 <= 300 ms` mixed-session generation gate.

Before further test or build execution, the final change was reviewed as a
static acceptance gate. Domain selection is persistence-agnostic and linear;
candidate snapshots are linear, their ordering is `O(n log n)`, and selected
IDs are resolved through dictionaries rather than repeated searches. Cache
invalidation distinguishes word-status changes from set-membership changes.
The Application coordinator still owns persistence orchestration, while quota,
overlap and fallback rules remain in the Domain policy. No new schema, network
request, main-thread task, full-history scan or quadratic candidate lookup was
introduced. Naming expresses policy roles and the focused helpers avoid adding
another persistence-aware scheduling abstraction.

## Verification

- Targeted Domain and Application policy/caching tests: passed.
- Four same-day Mixed sessions: 80 unique words with sufficient candidates.
- Date-boundary rotation: the next-day session excludes all 80 words presented
  in the preceding four sessions while lower-exposure candidates remain.
- Future-dated set exclusion and composition quota tests: passed.
- Release 10,000-word/10,000-session generation performance gate: passed.
- macOS and iOS target builds: passed.
- Swift style, Closed-Loop record validation and `git diff --check`: passed.

## Auditor Rework

The first Auditor review rejected four issues. Rework moved the 6/4/2/broad
composition into the shared Domain `SessionPolicy`, counts overlapping category
membership against every cap, prevents fallback from bypassing caps, includes
that shared policy in the iOS target, and splits status-cache invalidation from
set-membership invalidation. Architecture wording now matches same-direction
review relief. Focused regression tests cover cap overlap, reduced fallback and
Mastered-to-Active cache refresh.

## Relationships

- Preserves `CL-0006` same-day active-priority relief.
- Preserves `CL-0024` direction- and format-independent credit from `CL-0030`.
- Partially supersedes `CL-0009` only when due Mastered maintenance reserves
  previous-set capacity.
- Partially supersedes `CL-0030` fixed 30-day maintenance and 14-day failure
  blocking with post-failure relearning and adaptive intervals.
