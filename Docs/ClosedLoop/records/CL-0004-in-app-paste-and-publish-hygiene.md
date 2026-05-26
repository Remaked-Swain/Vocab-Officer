# CL-0004: In-App Paste Intake And Publish Hygiene

| Field | Value |
| --- | --- |
| Status | active |
| Date | 2026-05-26 (Asia/Seoul) |
| Scope | `Vocab/App/`, `Vocab/Presentation/`, `Vocab/Application/`, `VocabTests/`, `Tools/DailyIntakeImporter/`, `.gitignore`, `Docs/` |
| Agents | Director, Executor, Monitor, Recorder |
| Archive review | Retain while the application exposes paste intake or the repository is public |

## Decision

The primary daily-intake UX is an in-app paste editor with large readable
controls and a 100-item validation status. It accepts numbered hyphen-separated
lines and tab-separated lines, then passes parsed drafts to the existing atomic
daily-set save policy. Direct row entry remains available as a secondary
editing option with larger controls.

The earlier local operator intake tool is removed because the supported user
workflow now exists inside the application. Vocabulary payloads remain local
app data and are not durable Closed-Loop or Git artifacts.

| Supersedes in part | `CL-0003` |
| Superseded scope | Local external operator intake tool only |
| Remaining `CL-0003` scope | JSON/managed-backup removal and local deletion contract |

Before publishing revisions, the repository excludes app data stores, temporary
intake payloads, secrets/signing material, build/test outputs and Xcode
user-specific state. Existing evidence uses repository-relative paths only.

## Limitation

Published `origin/main` history contains one confirmed earlier absolute
development path in `CL-0001` test evidence. Removing already-published
history requires a separately approved history rewrite and force push; this
loop accepts and documents that existing exposure while preventing new
absolute-path publication from unpublished local commits.

## Verification Required

- Parser tests for numbered lines, tab-separated lines, internal punctuation,
  multiple meanings and malformed input.
- Full application tests and a macOS build for the new user-facing input flow.
- Tracked-file and history scans for common secrets, local databases, intake
  payload artifacts and absolute local paths.
