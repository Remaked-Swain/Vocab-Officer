# Vocab Architecture

## Purpose

`Vocab` is a macOS and iOS vocabulary trainer for an open-ended vocabulary
library and repeatable sessions of up to 20 distinct words. Both platforms
target OS 26 or newer using SwiftUI and SwiftData.

## Boundaries

| Layer | Responsibility |
| --- | --- |
| `Domain` | Pure policies: directions, judgement, failure history, active review, mastery, session composition |
| `Application` | Coordinates daily intake, sessions, final answer commits and deletion |
| `Data` | SwiftData persistence records and indexed summary state |
| `Infrastructure` | Normalization, Seoul calendar and measurement helpers |
| `Presentation` | Native macOS views, keyboard flows, confirmation and warnings |

The Domain layer must not import SwiftUI or SwiftData. UI does not decide
grading, mastery or deletion policy.

## Fixed Policies

- Intake accepts any positive number of words. Normalized headword is the SOT
  merge key across Active and Mastered records; duplicate meanings are ignored,
  new meanings are unioned, and the original registration date is preserved.
  Adding a new meaning to a Mastered word returns it to Active. Re-registering
  a deleted word creates a new identity.
- A test session contains no duplicate word and requests at most 20 words.
  User-facing modes are Today, Review and Mixed. Today uses the most recent
  `Asia/Seoul` registration day when nothing was registered today. Mixed uses
  bounded quotas for promotion due words,
  active review, due Mastered maintenance and broad historical rotation, then
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
- A word becomes `Mastered` after correct outcomes on two distinct Seoul
  dates regardless of mode, direction or question format. After a wrong or
  unknown outcome, only success days later than that failure count toward
  Mastered. Same-day repetitions can reduce active review priority but add at
  most one mastery day. A word with one eligible success day becomes
  promotion-due on the next Seoul date. Mastered maintenance expands through
  7, 14, 30 and at most 45 days as post-failure success evidence accumulates.
  Review reserves at most four due maintenance questions and Mixed at most two;
  a wrong/unknown result restores Active status.
- Mixed caps promotion-due words at six questions, active review at four and
  due Mastered maintenance at two. A word belonging to multiple categories
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

## Deletion Contract

Mastered status does not delete a word. The user must explicitly request
deletion and type confirmation text. Deletion removes identifiable word data
from the local app store while retaining aggregate counts that cannot be linked
back to the word.

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
