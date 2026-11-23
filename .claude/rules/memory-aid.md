---
paths:
  - "Vocab/Application/MemoryAidService.swift"
  - "Vocab/Presentation/MemoryAidViews.swift"
  - "VocabTests/Application/MemoryAidServiceTests.swift"
---

# Memory Aid (Gemini)

- Optional feature: the app must work fully without an API key. The key is
  entered in Settings and stored in Keychain, never in files or logs.
- Requests run off the UI path. Every response must pass
  `MemoryAidQualityGate`; failures queue repair prompts until the deadline,
  then surface a readable Korean error. Transient provider errors use the
  bounded retry schedule in `MemoryAidRequestPolicy`.
- Cache entries are keyed by prompt version; bump the version whenever prompt
  or gate semantics change so stale entries are skipped naturally.
- Retirement scrubs memory-aid caches and emits their tombstones.
