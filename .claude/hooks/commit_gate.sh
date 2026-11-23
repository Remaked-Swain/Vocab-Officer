#!/usr/bin/env bash
# PreToolUse(Bash): block `git commit` of gated paths unless the auditor
# approved exactly the current worktree.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input="$(cat)"
# Without jq, match against the raw payload rather than skipping the gate.
command="$(jq -r '.tool_input.command // empty' <<< "$input" 2>/dev/null)" || command="$input"
grep -Eq '(^|[^[:alnum:]_.-])git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$|")' \
  <<< "$command" || exit 0

# Once a commit is detected, any internal error blocks instead of failing open.
set -E
trap 'echo "Commit blocked: commit gate could not verify auditor approval." >&2; exit 2' ERR

root="$(vocab_root)"
git -C "$root" rev-parse --is-inside-work-tree > /dev/null
changed="$(vocab_changed_paths "$root")"
gated="$(grep -E "$VOCAB_GATED_PATHS" <<< "$changed" || true)"
[[ -n "$gated" ]] || exit 0

audit_dir="$(vocab_audit_dir "$root")"
current="$(vocab_worktree_fingerprint "$root")"
approved="$(cat "$audit_dir/approved" 2>/dev/null || true)"
[[ "$approved" == "$current" ]] && exit 0

{
  echo "Commit blocked: gated paths changed without a matching auditor approval."
  echo "Run the auditor subagent on the final worktree (audit skill); any edit after approval needs re-review."
  sed 's/^/  /' <<< "$gated" | head -20
} >&2
exit 2
