# CL-0011: OCR Intake, Input IO And Performance Refactor

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-06-24 (Asia/Seoul) |
| Scope | `Vocab/Presentation/TodayIntakeView.swift`, `Vocab/Application/OCRVocabularyFormatter.swift`, `Vocab/Application/LearningCoordinator.swift`, `VocabTests/Application/`, `Docs/Performance.md`, `Docs/ClosedLoop/` |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | retain while OCR intake, paste intake or documented performance acceptance exists |

## Problem

The daily intake path handles large paste text and multi-image OCR output. It
must stay responsive while preserving exactly-100 validation, local-only OCR,
and parenthesis-aware meaning handling.

The earlier implementation risked repeated paste parsing during SwiftUI body
evaluation and missed OCR rows when number or meaning tokens were vertically
offset or when digit-like characters were recognized as letters.

## Decision

- Paste/OCR text validation is cached in `PasteAnalysis`; count, status and save
  actions reuse the same parsed drafts instead of re-parsing in every view path.
- `DailyIntakePasteParser` streams non-empty lines and uses deterministic string
  scanning instead of compiling a regular expression per row.
- OCR formatter normalizes common number OCR mistakes such as `O501`, filters
  rows deterministically, and uses token-height-aware row matching instead of a
  single fixed y-axis threshold.
- OCR still produces editable paste-format text and never bypasses human review
  or `LearningCoordinator.saveDailySet`.
- Session generation stores presentation summaries and caches active word/set
  candidate pools within a coordinator lifecycle, preventing repeated
  broad-fetch work during repeated session generation.

## Targets

- 100-line paste/OCR validation: one parser pass per text mutation, p95 status
  update <= 150 ms.
- Paste parser: 100-line parse p95 <= 10 ms on the current Mac.
- OCR formatter fixture recall: at least 98 recognized rows per expected 100,
  with number-gap hints for remaining misses.
- OCR number cleanup: recover `O501`/`05O1` style number tokens in formatter
  tests.
- Session composition: 10,000-word/10,000-session mixed `generateSession` p95
  <= 300 ms including session save.

## Preserved Contracts

- `CL-0003`: no JSON import/export or app-managed backup path is restored.
- `CL-0004`: paste intake remains the primary bulk-entry contract.
- `CL-0010`: OCR and paste output preserve parenthesized-comma meanings through
  the same parser/splitter path.
- Daily-set save remains exactly-100, duplicate-safe and atomic.

## Excluded Scope

- No cloud OCR, network OCR, remote image upload or server-side processing.
- No automatic save from OCR without human review.
- No migration or rewrite of already stored vocabulary.
- No change to review scheduling, mastery, deletion or correction semantics.
- No claim that the original large-fixture p95 limitation is closed.

## Verification

- Formatter tests cover two-column extraction, multi-image sorting, shifted
  meaning-token recovery, duplicate number candidates and common number OCR
  cleanup.
- Learning coordinator tests cover parser compatibility and exactly-100 atomic
  save behavior.
- Changed-file verification included `TodayIntakeView`, OCR formatter,
  coordinator/parser, application tests, performance docs and this record.
- `OCRVocabularyFormatterTests` passed as a dedicated xcodebuild target.
- `script/measure_intake_performance.sh` passed in Release, including paste
  parser p95, noisy OCR recovery, 100-row OCR recall and the
  10,000-word/10,000-session mixed-session fixture.

## Limitation

OCR accuracy still depends on source screenshot quality and Vision output. The
app improves deterministic recovery and validation, but the user must continue
checking OCR text before saving.

## Relationships

This decision extends `CL-0004` and `CL-0010`, preserves the local-only data
contract from `CL-0003`, and closes the large-fixture session generation
measurement gap left in `CL-0001` for the current Release acceptance target.
