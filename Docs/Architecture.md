# Vocab Architecture

## Purpose

`Vocab` is a local-only macOS vocabulary training app for a daily set of
exactly 100 new headwords and repeatable sessions of up to 20 distinct words.
It targets macOS 14 or newer using SwiftUI and SwiftData.

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

- A completed daily intake contains exactly 100 newly learned headwords on an
  `Asia/Seoul` calendar day. Adding meanings to an existing headword is an
  edit, not a new intake item. Re-registering a deleted word counts as new.
- A test session contains no duplicate word and requests at most 20 words.
  Modes are Today, Selected Set, Review and Mixed. Selected Set allows an
  older completed intake set with untested words to be studied after later
  sets are registered. Mixed uses bounded quotas for the latest reference set,
  active review, due Mastered maintenance and broad historical rotation, then
  fills from the least-exposed eligible vocabulary. Category quotas apply only
  at the library's current minimum lifetime presentation count, so they cannot
  restart merely because the Seoul date changed.
- The learning-card screen groups vocabulary by completed intake set and lets
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
- A word becomes `Mastered` after correct outcomes on three distinct Seoul
  dates regardless of mode, direction or question format. After a wrong or
  unknown outcome, only success days later than that failure count toward
  Mastered. Same-day repetitions can reduce active review priority but add at
  most one mastery day. Mastered maintenance expands from 14 to 30, 60 and 120
  days as verified success days accumulate. Review reserves at most four due
  maintenance questions and Mixed at most two; a wrong/unknown result restores
  Active status.
- Mixed caps the current reference set at six questions, active review at four
  and due Mastered maintenance at two. A word belonging to multiple categories
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
  affecting UUID identity or normalized-headword SOT. Parsed drafts still pass
  through the same atomic daily-set policy; pasted vocabulary is never written
  to repository files by the app.
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
