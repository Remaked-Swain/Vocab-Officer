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
- OCR recognition (`OCRTextRecognizer`) reads each region twice: the
  Korean+English model for Hangul meanings, and the English-only model whose
  Latin tokens replace the mixed model's (it misreads small Latin, e.g. `d`
  as `a`). Lines Vision reads rotated 180° are dropped and re-read with the
  orientation flipped. A page whose pass had inverted lines, a median line
  height under 1.1% of the page, or fewer than 0.6 Latin lines per Hangul
  line is re-read in tiles (2×1, 2×2, 3×2) and merged by vote; a tile drops
  lines cut by its inner edges so fragments never out-vote whole lines. Small
  text is lost by its height relative to the page, not by pixels: the
  2,400 px downsample, `minimumTextHeight` and orientation hints do not
  change recall, and one tiling alone loses lines at its own edges. Pure
  merge and plan rules stay testable apart from Vision. Vision and
  downsampling run off the main actor; tiling stops on task cancellation.
- OCR formatting preserves selected page order, infers columns from
  number-token X clusters (4–8 digit numbers), opens a card block at each
  number, repairs `O`/`o` digit misreads, and uses token-height-aware rows. A
  page without numbered rows falls back to `OCRUnnumberedLayout`: a meaning
  pairs with the nearest headword to its left on its line, else the
  left-aligned headword just above; output is `headword<TAB>meanings`. When
  nothing pairs, the error says whether headwords, meanings or the pairing
  are missing.
- `OCRTokenClassifier` strips pronunciation from headwords: bracketed, IPA
  marks or `[` misread as `i`/`l`, keeping multiword, hyphenated and
  repeated-word terms (`hip hop`). A separate unbracketed token right after
  a headword with the same consonant skeleton (≥ 2 consonants) is its
  pronunciation; that rule never applies inside one token. Silent-letter
  transcriptions (`doubt daut`) are left for the reviewer: a looser match
  would cut phrases like `credit card`. A bracketed token with Latin letters
  is never a meaning.
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
