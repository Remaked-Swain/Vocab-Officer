---
name: verify
description: Select and run the smallest meaningful Vocab verification for the changed paths (focused XCTest classes, style check, harness self-test); --final adds full XCTest and platform builds after the stage.
---

```bash
.claude/skills/verify/select.sh [path...]          # plan only (Git-inferred paths when omitted)
.claude/skills/verify/select.sh --run [path...]    # plan and run focused checks
.claude/skills/verify/select.sh --final --run      # stage complete: full XCTest + builds
```

- Run the plan before testing and report the exact commands and results.
- Never run `--final` or a full build mid-stage without user approval;
  `script/build_and_run.sh --install-verify` is final-stage only.
- Broaden beyond the plan when persistence, shared contracts, project
  settings or release acceptance demand it, and say why.
- Performance-sensitive changes also run `script/measure_intake_performance.sh`
  at stage end (Release, see `.claude/rules/intake-ocr.md`).
