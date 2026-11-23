#!/usr/bin/env bash
# PostToolUse: run the repository Swift style check after a .swift edit.
# Silent on success; on failure exit 2 so the findings reach the main agent.
set -euo pipefail

file_path="$(jq -r '.tool_input.file_path // empty')"
[[ "$file_path" == *.swift ]] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
if ! output="$(PATH="$root/.claude/bin:$PATH" "$root/script/swift_style_check.sh" 2>&1)"; then
  printf 'script/swift_style_check.sh failed after editing %s:\n%s\n' "$file_path" "$output" >&2
  exit 2
fi
