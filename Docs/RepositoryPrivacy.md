# Repository Privacy Review

## Publishable Project Content

Application source, automated tests, architecture documents, Closed-Loop
decision summaries and project scripts may be versioned when they do not
contain vocabulary payloads, live databases, credentials or absolute local
paths.

## Excluded Local Content

The repository ignore rules exclude local SwiftData/SQLite/database files,
temporary bulk-intake files (`.tsv`, `.csv`, `.jsonl`), environment secret
files, signing material, provisioning profiles, build output, test output and
per-user Xcode state.

The in-app paste flow stores vocabulary directly in the local app database.
Vocabulary copied into the app must not be added to repository documentation,
test fixtures or Closed-Loop evidence.

## Audit Performed

On 2026-05-26, tracked files and local Git history were scanned for common
secret patterns, local database/build artifacts and persisted vocabulary
payloads. No credential-like secret or local database file was found in tracked
content. Two Closed-Loop evidence entries contained absolute development paths;
the current revision replaces them with repository-relative test result paths.

Published `origin/main` history was confirmed to contain one earlier absolute
local development path in test evidence. It may also retain implementation
removed by later local work. Removing material from already-published Git
history requires an explicit history rewrite and force push; it is not
performed as part of normal feature implementation. Unpublished local commits
are checked and consolidated before any future push so they do not introduce
new absolute paths.
