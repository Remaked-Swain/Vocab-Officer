---
paths:
  - "Vocab/Application/OCR*.swift"
  - "Vocab/Presentation/TodayIntakeView.swift"
  - "Vocab/Infrastructure/TextNormalizer.swift"
  - "VocabTests/Application/OCR*.swift"
  - "VocabTests/Fixtures/**"
  - "script/measure_intake_performance.sh"
---

# Intake, Paste And OCR

- Paste accepts `number-headword-meanings` and `headword<TAB>meanings` lines,
  including meanings starting with fullwidth `（`. Parsed drafts always go
  through the atomic vocabulary registration path; OCR output stays editable
  text and never bypasses human review.
- Printed numbers are transient locators, never identity. Gap diagnostics
  run in input order; a non-increasing number starts a new sequence.
- OCR preserves selected page order, infers columns from number-token X
  clusters (4–8 digit numbers), opens a card block at each number, strips
  pronunciation merged into headwords (keeping multiword/hyphenated terms),
  repairs `O`/`o` digit misreads, and uses token-height-aware rows. Vision and
  downsampling run off the main actor.
- One cached `PasteAnalysis` per text mutation; the parser streams lines
  without per-line regex.
- Vocabulary payloads never enter repository files, fixtures or evidence.

## Performance Acceptance

Release build, fixture of 10,000 words × ~3 meanings, 200,000 attempts,
10,000 corrections (`script/measure_intake_performance.sh`):

| Operation | Target |
| --- | ---: |
| Session composition | p95 ≤ 100 ms (≤ 300 ms incl. save, large fixture) |
| Automatic judgement + state update | p95 ≤ 50 ms |
| Manual correction recomputation | p95 ≤ 150 ms |
| Retirement / deletion | ≤ 3 s |
| Main-thread block during interaction | none > 100 ms |
| 100-line paste parse / status update | p95 ≤ 10 ms / ≤ 150 ms |
| 100-row OCR fixture recall | ≥ 98 rows |

## Pitfalls

- Vision's `usesLanguageCorrection` changes which Hangul glyphs come back
  per OS model: `false` (aea6a01) misreads 머뭇 as 머붓 on the macOS 27
  revision-3 model, `true` reads the reference fixture exactly. Re-check the
  reference image test when the OS changes; never loosen it to pass.
