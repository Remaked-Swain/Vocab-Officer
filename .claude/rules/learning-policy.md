---
paths:
  - "Vocab/Domain/**"
  - "Vocab/Application/LearningCoordinator.swift"
  - "Vocab/Application/WordLibrarySearch.swift"
  - "Vocab/Presentation/TestViews.swift"
  - "Vocab/Presentation/FeedbackPanel.swift"
  - "Vocab/Presentation/LibraryViews.swift"
  - "Vocab/Presentation/MasteredView.swift"
  - "Vocab/Presentation/Shared/**"
  - "VocabIOS/Presentation/**"
  - "VocabTests/Domain/**"
  - "VocabTests/Application/LearningCoordinatorTests.swift"
---

# Learning Policy

## Vocabulary

- `normalizedTerm` is the SOT merge key across nondeleted words. Exact
  duplicates are no-ops; new meanings are unioned. A new meaning on a
  consolidating word returns it to `active`. Deleted words are excluded from
  merge lookup; re-registration creates a new UUID.
- IDs are app-managed UUIDs (no `@Attribute(.unique)`). `createdAt` is the
  immutable first registration; grouping compares its `Asia/Seoul` day.
- Meaning trackability uses the parenthesis-aware `MeaningTextSplitter`: a
  meaning is trackable only when it splits to exactly one value. Legacy
  combined meanings never earn automatic or corrected credit.

## Sessions

- At most 20 distinct words; candidate-free starts fail with
  `noSessionCandidates` and persist nothing; never index an empty question
  list. Presentation owns the session and its questions as one value.
- Today: today's registrations, else the latest registration day.
- Review: up to 14 active-review candidates, up to 4 due consolidation
  maintenance, then the preceding registration day as bounded re-exposure.
- Mixed: caps of 6 promotion-due, 4 active-review, 2 due maintenance;
  multi-category words count against every cap; broad rotation fills the
  rest (normally at least 8) and capped categories never backfill it. Order by
  lower lifetime exposure, then older presentation. No word repeats on the
  same Seoul day while an eligible unseen word remains; quotas select only at
  the library's current minimum presentation count. Future-dated words are
  excluded.
- Generation uses presentation summaries and cached candidate pools, never
  full attempt-history scans.

## Grading

- English→Korean accepts any one stored meaning or approved alias and tracks
  each core meaning; Korean→English tracks per word. Near typos are never
  auto-correct: the user accepts once or adds an approved answer (Mac only).
- The acknowledgement panel shows headword, all meanings and the submitted
  answer before confirm/correct; `unknown` is an immediate failure.
- Multiple choice (`QuestionFormat.multipleChoice`): one correct + three
  seeded-shuffled distractors; questions lacking distractors are dropped;
  attempts store the selected label.
- `failureCheck` is historical (+1 per final wrong/unknown, max 3, never
  reduced). `activePriority` is separate: two consecutive E→K correct reduce
  it by one; two consecutive correct in both directions also reduce it and
  reset both streaks. A corrected automatic mistake never commits a failure.

## Lifecycle

- Evidence: one success per Seoul date; any mode, direction or format; only
  dates after the latest wrong/unknown (or SOT revision) count.
- `consolidating` (`장기정착`): two eligible dates; one date makes the word
  promotion-due from the next day. Excluded from ordinary rotation;
  maintenance after 7/14/30/45 days (2/3/4/5+ dates). Wrong/unknown returns
  it to `active`.
- `masteredV2` (`암기완료`, terminal): five eligible dates, ≥45-day span,
  ≥30 days between the last two; meaning coverage not required. Legacy
  `mastered` migrates to `consolidating` and is never auto-retired.
- Retirement runs in a background model actor: scrub identifying word,
  meaning, attempt, review and memory-aid content, unlink sessions,
  soft-delete, emit tombstones for every identifying record type, keep only an
  unlinkable daily count. Report delay after 200 ms without blocking UI.
  Bound: `O(W + I + S + M + A)`.
- Learning cards group by registration day and toggle headword/meanings
  without changing progress. Review grid cards are static, adaptive
  (min 210 pt, 16 pt spacing), never truncate meanings, and carry
  accessibility labels.

## Shared Presentation

- `Vocab/Presentation/Shared/` compiles into both targets (iOS lists each
  file in the project); macOS and iOS compose its cards, test components and
  display mappings instead of duplicating them. It holds display only.
- Review lists on both platforms come from `ReviewCandidateList`: active,
  nondeleted words with positive priority, by priority, failure checks, then
  oldest presentation. Registration-day grouping is rebuilt per library
  change, never per render.
- iOS tabs mirror the Mac learning section (테스트, 학습 카드, 복습) in name,
  symbol and order; page titles come from the navigation item name.
- A finished test shows a completion summary before closing; the tally is
  display-only and never feeds grading.
