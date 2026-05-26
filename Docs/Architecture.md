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
  sets are registered. Mixed selects up to 10 review words plus up to 10
  untested today words, then uses remaining words from either pool.
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
- `activePriority` is separate and can be reduced only after both directions
  reach two consecutive correct outcomes.
- A word becomes `Mastered` only after every core meaning has three distinct
  Seoul-day English-to-Korean successes, Korean-to-English has three distinct
  Seoul-day successes, and no wrong/unknown answer occurred in the last 14
  Seoul days.
- The intake screen supports a local paste flow for either
  `number-headword-meanings` lines or tab-separated `headword<TAB>meanings`
  lines. Parsed drafts still pass through the same atomic daily-set policy;
  pasted vocabulary is never written to repository files by the app.

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
