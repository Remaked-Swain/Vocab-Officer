#!/usr/bin/env bash
# PostToolUse: lint after editing a .swift file or the lint rules themselves.
# Silent on success; on failure exit 2 so the findings reach the main agent.
set -euo pipefail

file_path="$(jq -r '.tool_input.file_path // empty')"
case "$file_path" in
  *.swift|*/.claude/lint/*) ;;
  *) exit 0 ;;
esac

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
if ! output="$("$root/.claude/lint/swift_lint.sh" 2>&1)"; then
  printf 'Swift lint failed after editing %s:\n%s\n' "$file_path" "$output" >&2
  exit 2
fi
