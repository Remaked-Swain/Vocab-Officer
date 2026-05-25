# Performance Acceptance

All acceptance measurements use a Release build on the current development Mac
(`macOS 26.5`, `Xcode 26.0.1`) and a fixture containing:

- 10,000 words
- three core meanings per word on average
- 200,000 answer attempts
- 10,000 judgement corrections
- three app-managed backups

| Operation | Requirement |
| --- | ---: |
| Session composition | p95 <= 100 ms |
| Automatic judgement and state update | p95 <= 50 ms |
| Manual correction recomputation | p95 <= 150 ms |
| JSON export | <= 3 s |
| JSON import/restore | <= 5 s |
| Mastered deletion and managed-backup scrub | <= 3 s |
| Main-thread blocking during interaction | no interval > 100 ms |

Normal session generation and grading must use summary state and limited
queries, not scans over full attempt history. JSON export/import and scrub are
linear data operations and must execute outside the UI interaction path.

