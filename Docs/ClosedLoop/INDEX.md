# Closed-Loop Decision Index

Read this file at the start of a new Closed-Loop task. Read a linked record
only when its scope applies to the current change.

| ID | Status | Date | Scope | Record | Review |
| --- | --- | --- | --- | --- | --- |
| CL-0001 | active | 2026-05-25 | vocabulary rules, persistence, backup, UI foundation | [Vocab MVP implementation](records/CL-0001-vocab-mvp-implementation.md) | retain while app exists |
| CL-0002 | active | 2026-05-25 | Closed-Loop operations, record retention, targeted verification; startup scheduling partially superseded by CL-0012 | [Durable records and selective verification](records/CL-0002-durable-records-and-selective-verification.md) | 2026-08-23 |
| RUN-20260525-CL0002 | completed | 2026-05-25 | workflow implementation evidence | [Run record](runs/RUN-20260525-CL0002.md) | completed after Monitor and Director approval |
| CL-0003 | active | 2026-05-26 | local data entry, JSON/managed-backup removal | [Local-only intake without JSON backup features](records/CL-0003-local-intake-without-json-backup.md) | retain while app exists |
| RUN-20260526-CL0003 | completed | 2026-05-26 | feature removal and 2026-05-25 intake execution | [Run record](runs/RUN-20260526-CL0003.md) | completed after Monitor, Director and Recorder approval |
| CL-0004 | active | 2026-05-26 | in-app paste intake, accessibility and repository publishing hygiene | [In-app paste intake and publish hygiene](records/CL-0004-in-app-paste-and-publish-hygiene.md) | retain while feature or public repository exists |
| RUN-20260526-CL0004 | completed | 2026-05-26 | accessible paste intake and repository hygiene execution | [Run record](runs/RUN-20260526-CL0004.md) | completed after Director, Monitor and Recorder approval |
| CL-0005 | active | 2026-05-26 | selected-set testing, study cards, judgement transparency and local installation | [Study cards, selected-set testing and local installation](records/CL-0005-study-cards-selected-set-testing-and-installation.md) | retain while feature exists |
| RUN-20260526-CL0005 | completed | 2026-05-26 | defect repair, card study and installation evidence | [Run record](runs/RUN-20260526-CL0005.md) | completed after Director, Monitor and Recorder approval |
| CL-0006 | active | 2026-05-28 | English-to-Korean review priority decay and review eligibility | [English-to-Korean review decay](records/CL-0006-english-to-korean-review-decay.md) | retain while scheduler exists |
| CL-0007 | active | 2026-06-09 | session bootstrap, sandbox awareness and Swift/Xcode-first tooling; pre-spawn briefing partially superseded by CL-0012 | [Session bootstrap and tooling discipline](records/CL-0007-session-bootstrap-and-tooling-discipline.md) | retain while Codex workflow exists |
| CL-0008 | active | 2026-06-10 | loose-word test eligibility and fair presentation | [Loose word testing](records/CL-0008-loose-word-testing.md) | retain while loose-word intake and testing exist |
| CL-0009 | active | 2026-06-12 | review-mode previous-set re-exposure and 14+6 selection | [Previous-set review re-exposure](records/CL-0009-previous-set-review-reexposure.md) | retain while review-session selection exists |
| CL-0010 | active | 2026-06-17 | parenthesized-comma meaning tracking and correction | [Parenthesized-comma meaning tracking](records/CL-0010-parenthesized-comma-meaning-tracking.md) | retain while correction and meaning-tracking behavior exists |
| CL-0011 | active | 2026-06-24 | OCR intake, input IO and performance refactor | [OCR intake, input IO and performance refactor](records/CL-0011-ocr-intake-input-io-performance-refactor.md) | retain while OCR intake, paste intake or performance acceptance exists |
| CL-0012 | superseded | 2026-06-28 | historical four-role sequential handoffs; replaced by CL-0025 | [Sequential agent handoffs](records/CL-0012-sequential-agent-handoffs.md) | retain through 2026-12-02 |
| CL-0013 | active | 2026-06-28 | `Vocab/Presentation/LibraryViews.swift` and review UI | [Review grid cards](records/CL-0013-review-grid-cards.md) | retain while review UI exists |
| CL-0014 | active | 2026-07-14 | automatic batch iCloud sync, snapshot cursor and conflict stop | [Automatic batch iCloud sync](records/CL-0014-automatic-batch-icloud-sync.md) | retain while iCloud sync or migration behavior exists |
| CL-0015 | superseded | 2026-07-14 | historical Director-gated four-role workflow; replaced by CL-0025 | [Director-gated Closed-Loop use](records/CL-0015-director-gated-closed-loop.md) | retain through 2026-12-02 |
| CL-0016 | active | 2026-07-14 | per-record SwiftData CloudKit mirroring, V3 export receipt, tuple recovery, canonical fingerprint and migration safety | [Per-record CloudKit mirroring migration](records/CL-0016-per-record-cloudkit-mirroring.md) | code-level approved; real-device CloudKit export/import and bidirectional propagation pending |
| CL-0017 | active | 2026-07-15 | CloudKit reconcile scheduling and actor isolation; foreground/import audit scheduling partially superseded by CL-0026 | [CloudKit reconciliation scheduling](records/CL-0017-cloudkit-reconciliation-scheduling.md) | retain while per-record CloudKit reconciliation and hydration scheduling exist |
| CL-0018 | superseded | 2026-07-15 | historical four-role session reuse; replaced by CL-0025 | [Run-scoped role agent reuse](records/CL-0018-run-scoped-role-agent-reuse.md) | retain through 2026-12-02 |
| CL-0019 | active | 2026-07-18 | explicit `Vocab.store` recovery, fail-closed CloudKit write authorization and automatic replica refresh limitation superseded by CL-0020 | [Explicit recovery and CloudKit write safety](records/CL-0019-explicit-recovery-and-cloudkit-write-safety.md) | retain while mirrored-store recovery or CloudKit authoring exists |
| CL-0020 | active | 2026-07-18 | foreground-safe automatic `Vocab.store` recovery-replica refresh, background-safe scheduling and publication guards | [Foreground-safe recovery replica refresh](records/CL-0020-foreground-safe-recovery-replica-refresh.md) | retain while automatic recovery-replica refresh or mirrored-store recovery exists |
| CL-0021 | active | 2026-07-18 | macOS foreground authoring continuity, mutation authority validation and MemoryAid/Gemini response quality | [Foreground authoring and MemoryAid quality](records/CL-0021-foreground-authoring-and-memory-aid-quality.md) | retain while CloudKit authoring authorization or MemoryAid generation exists |
| CL-0022 | active | 2026-07-18 | iOS ready/audited mirrored-store learning facts, Mac-only vocabulary authoring, foreground epoch continuity and mutation-lease test isolation | [iOS learning facts offline authority](records/CL-0022-ios-learning-facts-offline-authority.md) | retain while iOS learning sessions or CloudKit mutation authorization exist |
| CL-0023 | active | 2026-07-18 | store notifications and mutation authority; successful-import invalidation partially superseded by CL-0026 | [Store notification mutation authority](records/CL-0023-store-notification-mutation-authority.md) | retain while CloudKit mutation authorization or SwiftData mirroring exists |
| CL-0024 | active | 2026-07-31 | four-choice test format, distractor generation, Mac/iOS test UX and sync payload compatibility | [Multiple choice test mode](records/CL-0024-multiple-choice-test-mode.md) | retain while multiple-choice testing exists |
| CL-0025 | active | 2026-09-03 | main-agent implementation, one read-only Auditor, two-role pipeline and scoped durable evidence | [Main and Auditor Closed-Loop](records/CL-0025-main-auditor-closed-loop.md) | retain while Codex workflow uses this harness |
| CL-0026 | active | 2026-09-03 | foreground-safe changed-ID CloudKit import reconciliation and deferred full audit | [Foreground incremental Cloud import](records/CL-0026-foreground-incremental-cloud-import.md) | retain while per-record CloudKit synchronization exists |
| CL-0027 | active | 2026-09-04 | unbounded Auditor rejection and Main rework loop | [Unbounded Auditor rework](records/CL-0027-unbounded-auditor-rework.md) | retain while Codex workflow uses this harness |
| CL-0028 | active | 2026-09-04 | Swift conventions, objective style checks, and contextual audit | [Swift coding conventions](records/CL-0028-swift-coding-conventions.md) | retain while Swift code is maintained |
| CL-0029 | active | 2026-10-08 | restarted printed numbering, adaptive OCR layout and reset-aware gap diagnostics | [Restarted source numbering and adaptive OCR](records/CL-0029-restarted-source-numbering-and-adaptive-ocr.md) | retain while numbered paste or image OCR intake exists |
| CL-0030 | active | 2026-10-08 | direction-agnostic mastery, multiple-choice credit and periodic revalidation | [Direction-agnostic mastery and revalidation](records/CL-0030-direction-agnostic-mastery-revalidation.md) | retain while Mastered lifecycle exists |
| CL-0031 | active | 2026-11-09 | spaced relearning, adaptive Mastered maintenance and same-day Mixed rotation | [Spaced relearning and Mixed rotation](records/CL-0031-spaced-relearning-and-mixed-rotation.md) | retain while test scheduling or Mastered lifecycle exists |
| CL-0032 | active | 2026-11-13 | two-date Mastered promotion, exam-horizon maintenance and promotion-due Mixed quota | [Exam-horizon Mastery promotion](records/CL-0032-exam-horizon-mastery-promotion.md) | retain while test scheduling or Mastered lifecycle exists |
| CL-0033 | active | 2026-11-13 | setless vocabulary registration, registration-day grouping and legacy compatibility | [Setless vocabulary registration](records/CL-0033-setless-vocabulary-registration.md) | retain while vocabulary persistence or intake exists |
| CL-0034 | active | 2026-11-17 | terminal mastery, long-term consolidation, automatic scrub and resurrection prevention | [Terminal mastery and automatic retirement](records/CL-0034-terminal-mastery-retirement.md) | retain while learning lifecycle, deletion, CloudKit or recovery exists |
| CL-0035 | active | 2026-11-18 | immutable Main evidence for CL-0034 re-audit | [Terminal mastery rework submission](records/CL-0035-terminal-mastery-rework-submission.md) | retain with CL-0034 |
| CL-0036 | completed | 2026-11-18 | final read-only audit approval for terminal mastery | [Terminal mastery audit approval](audits/RUN-20261117-CL0034-audit.md) | retain with CL-0034 |
| CL-0037 | active | 2026-11-19 | agent bootstrap, rule routing, selective document loading, harness verification | [Context routing harness](records/CL-0037-context-routing-harness.md) | retain while Codex workflow uses this harness |

## Context Routing

Use `script/route_context.sh` with `--intent inspect|change`, task tags and
intended changed paths. Its manifest, `Docs/Rules/context-routes.json`, is the
executable source of truth for selective document loading. Read this full
ledger only when maintaining a durable record, investigating history or
following an explicit route.

Superseded and archived records are never routed by default. The router
validates that every routed Closed-Loop record is indexed and active.
`script/verify_changed.sh` remains the independent executable source of truth
for test-impact selection.
