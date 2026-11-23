---
name: convention
description: Add, change or remove a Vocab convention (coding style, lint ban, architecture boundary, Git/PR/issue process) from a natural-language instruction, placing each part where it is loaded and enforced.
---

## 1. Split the instruction

One instruction often has several parts. For each part decide:

| Part is… | Put it in |
| --- | --- |
| Mechanically detectable per line (API, keyword, import) | a block in `.claude/lint/swift.rules` |
| Judgement ("prefer", "avoid unless", design intent) | a bullet in the matching `.claude/rules/<area>.md` |
| Product, workflow, Git, PR, issue, privacy | `CLAUDE.md` section |
| Lesson from a failed attempt | `## Pitfalls` in the area rule, with commit hash |

Pick the area file whose `paths:` match where the rule applies. Create a new
`.claude/rules/<area>.md` with `paths:` only when no existing file fits.
Never duplicate a rule across places; prose may point at a lint id.

## 2. Edit

- Lint block: `id`, `message`, `pattern` (PCRE), `paths` if narrower than
  all targets, `allow` for an audited escape hatch, and a one-line violating
  `example` (required; the self-test proves it fails).
- Existing violations the user does not want fixed now: add
  `baseline = <id>.txt` and run `.claude/lint/swift_lint.sh --baseline <id>`
  to freeze them as backlog. Otherwise fix them in the same change.
- Changing or removing: edit or delete the block/bullet, then delete an
  unused baseline file.
- Contradicting an existing rule: state the conflict and ask which wins.

## 3. Check

```bash
.claude/lint/swift_lint.sh --self-test && .claude/lint/swift_lint.sh
.claude/hooks/self_test.sh
```

Then use the `audit` skill. Report what was placed where, e.g.:

> "Ban GCD/Swift Concurrency mixing; avoid NSLock control outside actors" →
> lint `legacy-concurrency` (frozen baseline) + `.claude/rules/swift.md`
> Concurrency bullets.
