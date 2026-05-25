# Vocab Architecture

## Purpose

`Vocab` is a local-only macOS vocabulary training app for a daily set of
exactly 100 new headwords and repeatable sessions of up to 20 distinct words.
It targets macOS 14 or newer using SwiftUI and SwiftData.

## Boundaries

| Layer | Responsibility |
| --- | --- |
| `Domain` | Pure policies: directions, judgement, failure history, active review, mastery, session composition |
| `Application` | Coordinates daily intake, sessions, final answer commits, deletion and restoration |
| `Data` | SwiftData persistence records and indexed summary state |
| `Infrastructure` | Normalization, Seoul calendar, JSON backup/scrub and measurement helpers |
| `Presentation` | Native macOS views, keyboard flows, confirmation and warnings |

The Domain layer must not import SwiftUI or SwiftData. UI does not decide
grading, mastery or deletion policy.

## Fixed Policies

- A completed daily intake contains exactly 100 newly learned headwords on an
  `Asia/Seoul` calendar day. Adding meanings to an existing headword is an
  edit, not a new intake item. Re-registering a deleted word counts as new.
- A test session contains no duplicate word and requests at most 20 words.
  Modes are Today, Review and Mixed. Mixed selects up to 10 review words plus
  up to 10 untested today words, then uses remaining words from either pool.
- English-to-Korean accepts one stored meaning or explicitly approved alias per
  question, while tracking each core meaning separately for mastery.
  Korean-to-English tracks recall per word.
- Normalization supports trimming, whitespace/punctuation normalization and
  case-insensitive English comparison. A near typo is never automatically
  correct; the user can accept it once or add it as an approved answer.
- `failureCheck` is historical: each final wrong/unknown outcome increments it
  to a maximum of three. It is not reduced by correct answers or mastery.
  A corrected automatic mistake never commits the invalid failure event.
- `activePriority` is separate and can be reduced only after both directions
  reach two consecutive correct outcomes.
- A word becomes `Mastered` only after every core meaning has three distinct
  Seoul-day English-to-Korean successes, Korean-to-English has three distinct
  Seoul-day successes, and no wrong/unknown answer occurred in the last 14
  Seoul days.

## Deletion Contract

Mastered status does not delete a word. The user must explicitly request
deletion and type confirmation text after seeing this limitation:

> Vocab can remove identifiable data from the app and backups it manages. It
> cannot find or delete JSON copies exported elsewhere.

Deletion removes identifiable word data and related managed-backup entries,
while retaining aggregate counts that cannot be linked back to the word.

