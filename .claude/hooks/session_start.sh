#!/usr/bin/env bash
# Expose the ripgrep shim to every Bash command in this session. Prints nothing
# so it adds no context tokens.
set -euo pipefail

[[ -n "${CLAUDE_ENV_FILE:-}" ]] || exit 0
printf 'export PATH="%s/.claude/bin:$PATH"\n' "$CLAUDE_PROJECT_DIR" >> "$CLAUDE_ENV_FILE"
