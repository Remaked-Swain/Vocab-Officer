# Performance Acceptance

All acceptance measurements use a Release build on the current development Mac
(`macOS 26.5`, `Xcode 26.0.1`) and a fixture containing:

- 10,000 words
- three core meanings per word on average
- 200,000 answer attempts
- 10,000 judgement corrections

| Operation | Requirement |
| --- | ---: |
| Session composition | p95 <= 100 ms |
| Automatic judgement and state update | p95 <= 50 ms |
| Manual correction recomputation | p95 <= 150 ms |
| Mastered deletion | <= 3 s |
| Main-thread blocking during interaction | no interval > 100 ms |

Normal session generation and grading must use summary state and limited
queries, not scans over full attempt history.

## Refactor Targets

The 2026-06-24 performance pass sets the following measurable targets:

| Area | Previous Risk | Target |
| --- | --- | ---: |
| 100-line paste/OCR text validation | SwiftUI render paths parsed the same long text multiple times | one parser pass per text mutation, paste status update p95 <= 150 ms |
| Paste parser implementation | per-line regular expression work and array materialization | 100-line parse p95 <= 10 ms on the current Mac |
| OCR row recovery | fixed vertical threshold could silently drop shifted meaning tokens | fixture recall >= 98 rows per 100, number-gap hints for remaining misses |
| OCR number cleanup | common `O`/`o` digit mistakes could drop rows | recover `O501`/`05O1` style number tokens in formatter tests |
| Session composition | repeated SwiftData fetches and full session-history scans remain risky | large-fixture `generateSession` p95 <= 300 ms including session save |

Current status:

- Paste validation now keeps one cached analysis state for the current text.
- Paste parsing now streams lines and avoids per-line regular-expression
  compilation.
- OCR formatting now normalizes common number OCR mistakes and uses token-height
  aware row matching. The 100-row OCR fixture must recover at least 98 rows.
- Session generation stores per-word presentation summaries and caches the
  active word/set candidate pools within a coordinator lifecycle, so repeated
  sessions do not rescan full historical `TestSessionRecord` data.
- `script/measure_intake_performance.sh` runs Release acceptance coverage for
  paste parsing, noisy OCR recovery, 100-row OCR recall, and a
  10,000-word/10,000-session mixed-session fixture.
