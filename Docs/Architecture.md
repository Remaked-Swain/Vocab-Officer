# Vocab Architecture

## Purpose

`Vocab` is a macOS and iOS vocabulary trainer for an open-ended vocabulary
library and repeatable sessions of up to 20 distinct words. Both platforms
target OS 26 or newer using SwiftUI and SwiftData.

## Boundaries

| Layer | Responsibility |
| --- | --- |
| `Domain` | Pure policies: directions, judgement, failure history, active review, mastery, session composition |
| `Application` | Coordinates vocabulary intake, sessions, final answer commits and automatic retirement |
| `Data` | SwiftData persistence records and indexed summary state |
| `Infrastructure` | Normalization, Seoul calendar and measurement helpers |
| `Presentation` | Native macOS views, keyboard flows, confirmation and warnings |

The Domain layer must not import SwiftUI or SwiftData. UI does not decide
grading, mastery or deletion policy.

## Fixed Policies

- Intake accepts any positive number of words. Normalized headword is the SOT
  merge key across nondeleted records; duplicate meanings are ignored,
  new meanings are unioned, and the original registration date is preserved.
  Adding a new meaning to a consolidating word returns it to Active. Re-registering
  a deleted word creates a new identity.
- A test session contains no duplicate word and requests at most 20 words.
  User-facing modes are Today, Review and Mixed. Today uses the most recent
  `Asia/Seoul` registration day when nothing was registered today. Mixed uses
  bounded quotas for promotion due words,
  active review, due long-term consolidation maintenance and broad historical rotation, then
  fills from the least-exposed eligible vocabulary. Category quotas apply only
  at the library's current minimum lifetime presentation count, so they cannot
  restart merely because the Seoul date changed.
- The learning-card screen groups vocabulary by first registration day and lets
  each card toggle between headword and all registered meanings without
  changing progress.
- English-to-Korean accepts one stored meaning or explicitly approved alias per
  question, while tracking each core meaning separately for mastery.
  Korean-to-English tracks recall per word.
- Normalization supports trimming, whitespace/punctuation normalization and
  case-insensitive English comparison. A near typo is never automatically
  correct; the user can accept it once or add it as an approved answer.
- The acknowledgement panel for an automatic correct or incorrect answer
  displays the headword, all registered meanings and submitted answer before
  the user confirms or corrects the final result.
- `failureCheck` is historical: each final wrong/unknown outcome increments it
  to a maximum of three. It is not reduced by correct answers or mastery.
  A corrected automatic mistake never commits the invalid failure event.
- `activePriority` is separate. Two consecutive English-to-Korean correct
  outcomes can reduce it by one; reaching two consecutive correct outcomes in
  both directions also reduces it and resets both streaks.
- A word enters `consolidating` (`장기정착`) after correct outcomes on two
  distinct Seoul dates regardless of mode, direction or question format. It is
  excluded from ordinary rotation but returns for spaced maintenance at 7, 14,
  30 and at most 45 days. A wrong or unknown outcome restores `active`.
- Terminal `masteredV2` (`암기완료`) requires five distinct eligible success
  dates after the latest wrong/unknown result or SOT revision, at least 45 days
  between first and final evidence, and at least 30 days between the last two
  evidence dates. Same-day repetitions count once. Any direction and typed or
  multiple-choice format may supply evidence; all meanings need not be covered.
  Existing legacy `mastered` values migrate to `consolidating` and are never
  treated as terminal cleanup candidates merely because of their old status.
- Mixed caps promotion-due words at six questions, active review at four and
  due consolidation maintenance at two. A word belonging to multiple categories
  counts against every applicable cap. Historical-set and loose words fill the
  remaining capacity, normally at least eight questions; capped categories do
  not backfill a missing broad pool. Candidates are ordered by lower lifetime
  exposure and older presentation time. No word already
  presented on the current Seoul day is reused while any eligible unseen word
  remains. Across dates, a higher presentation-count word cannot consume a
  category quota while a lower-count eligible word remains; equal counts prefer
  the oldest presentation time.
- The intake screen supports a local paste flow for either
  `number-headword-meanings` lines or tab-separated `headword<TAB>meanings`
  lines. Printed numbers are transient source locators and may restart without
  affecting UUID identity or normalized-headword SOT. Parsed drafts pass
  through the same atomic vocabulary registration policy; pasted vocabulary is never written
  to repository files by the app.
- `DailySetRecord` and `DailySetItemRecord` remain in the persistence graph only
  for legacy store and CloudKit compatibility. Current product flows do not
  create or display new set records.
- Image OCR infers columns and vocabulary-card blocks from number positions,
  removes pronunciation text merged with a headword, and preserves selected
  page order. Vision recognition and image downsampling run off the main actor.

## Automatic Retirement Contract

`암기완료` is a terminal transition. A background model actor removes the word
from active product queries, scrubs identifying word, meaning, attempt, review
and memory-aid content, removes session references, and writes per-record
tombstones plus an unlinkable aggregate count. Tombstones remain in the local,
CloudKit and recovery graphs so an older peer cannot resurrect retired content.
The UI reports delayed cleanup without blocking interaction.

The app does not expose JSON import, JSON export or managed-backup features.

## Local Installation

`script/build_and_run.sh --install-verify` builds the Release app, installs it
at `/Applications/Vocab.app` and launches it for local-use verification.
Application data stays in the macOS application-support store and is not
bundled into the installed executable.

## iCloud And iPhone Direction

iCloud/iPhone work must be isolated from the stable macOS app. The codebase now
uses `VocabModelContainerFactory` as the single SwiftData container boundary.
Its default mode is `localOnly`, which preserves the current macOS store path.
`cloudKitPrivate` exists as the explicit CloudKit preparation point for
`iCloud.com.swainyun.Vocab`, but it must not become the default until signing,
CloudKit schema compatibility and first-device migration are verified.

See `Docs/iCloudIOSSyncPlan.md` for the staged implementation policy.
