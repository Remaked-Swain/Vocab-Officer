# Verification Checklist

- Save exactly 100 new headwords; reject 99, 101, duplicates and existing-word edits.
- Paste 100 lines in the supported in-app formats, preserving internal
  punctuation in headwords and multiple meanings; reject malformed lines.
- Generate Today, Review and Mixed sessions with at most 20 distinct words and
  visibly reduced sessions when fewer candidates exist.
- Test both directions, multiple core meanings, registered aliases, typo
  suggestions and manual judgement corrections.
- Confirm `failureCheck` remains historical while `activePriority` recovers
  only through two-correct streaks in both directions.
- Confirm Seoul-day mastery counts, 14-day failure blocking and Mastered
  removal from active testing.
- Confirm deletion warning, local identifiable-data removal and aggregate
  preservation.
- Confirm no learning payload, local SwiftData store, secret material or test
  result bundle is tracked in Git before publishing.
- For each Closed-Loop change, read `Docs/ClosedLoop/INDEX.md` and run
  `script/verify_changed.sh` with only that loop's affected files before
  broadening verification scope.
- Run unit tests, build the macOS target and execute the performance harness
  against the documented fixture before final acceptance.
