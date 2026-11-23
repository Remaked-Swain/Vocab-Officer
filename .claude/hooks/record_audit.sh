#!/usr/bin/env bash
# SubagentStop: bind the auditor's verdict to the current worktree fingerprint.
# Main never writes these files; only this hook does.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input="$(cat)"
[[ "$(jq -r '.agent_type // empty' <<< "$input")" == "auditor" ]] || exit 0

message="$(jq -r '.last_assistant_message // empty' <<< "$input")"
# A subagent that reports through the SubagentHandback tool leaves no final
# text, so fall back to the last text or hand-back message in its transcript.
transcript="$(jq -r '.agent_transcript_path // empty' <<< "$input")"
if [[ -z "${message//[[:space:]]/}" && -f "$transcript" ]]; then
  message="$(jq -rs '
    [ .[] | select(.type == "assistant") | .message.content[]?
      | if .type == "text" then .text
        elif .type == "tool_use" and .name == "SubagentHandback" then .input.message
        else empty end
      | select(. != null and . != "") ]
    | last // empty' "$transcript")"
fi
# First "Decision: approve|reject" line wins; markdown emphasis is ignored.
decision="$(tr -d '*_`' <<< "$message" | awk '
  {
    line = tolower($0)
    if (line !~ /^[[:space:]]*decision:[[:space:]]*(approve|reject)([^[:alpha:]]|$)/) next
    sub(/^[[:space:]]*decision:[[:space:]]*/, "", line)
    print (line ~ /^approve/) ? "approve" : "reject"
    exit
  }')"

root="$(vocab_root)"
dir="$(vocab_audit_dir "$root")"
mkdir -p "$dir"
fingerprint="$(vocab_worktree_fingerprint "$root")"

if [[ "$decision" == "approve" ]]; then
  printf '%s\n' "$fingerprint" > "$dir/approved"
else
  rm -f "$dir/approved"
fi
printf '%s\n' "$message" > "$dir/last-verdict.md"
printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(jq -r '.agent_id // "-"' <<< "$input")" "${decision:-none}" "$fingerprint" >> "$dir/log.tsv"
