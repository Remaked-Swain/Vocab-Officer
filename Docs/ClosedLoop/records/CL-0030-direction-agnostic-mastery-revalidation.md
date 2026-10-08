# CL-0030: Direction-Agnostic Mastery And Revalidation

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-10-08 (Asia/Seoul) |
| Scope | mastery evidence, multiple-choice credit, review and mixed session composition |
| Review | main-agent verification; user explicitly allowed completion without a subagent |
| Archive review | retain while Mastered lifecycle exists |

## Problem

Requiring both English-to-Korean and Korean-to-English evidence prevented users
who primarily study in one direction from reaching Mastered. Permanently
excluding Mastered words also removed the observation path needed to discover
forgotten vocabulary.

## Decision

- A word reaches Mastered after correct outcomes on three distinct Seoul dates,
  regardless of test mode, direction, or typed versus multiple-choice format.
- Existing per-meaning English-to-Korean dates and word-level
  Korean-to-English dates are combined as word-level evidence. This avoids a
  persistence migration and preserves historical evidence.
- A wrong or unknown result within the latest 14 days continues to block
  Mastered.
- Mastered words whose last test is at least 30 days old become maintenance
  candidates in Review and Mixed sessions.
- Maintenance contributes at most two questions per session and reserves space
  only when eligible candidates exist, preserving the existing Review `14+6`
  behavior otherwise.
- A final wrong or unknown maintenance result immediately restores the word to
  Active and reactivates review priority.

## Verification

Domain tests cover one-direction-only mastery in both directions, the recent
failure block and the 30-day maintenance boundary. Application tests cover
multiple-choice mastery credit, three-day multiple-choice mastery, maintenance
selection, demotion after a wrong answer and preservation of the existing
review composition.

`DomainModels.swift` and `StudyPolicies.swift` are explicit sources of both the
macOS and iOS targets, so both platforms compile the same mastery implementation.
The generic iOS device build is part of compatibility verification.

## Compatibility

The policy uses existing summary fields and `lastTestedAt`. SwiftData,
CloudKit payloads and snapshot schemas are unchanged.
