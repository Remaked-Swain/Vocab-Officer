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
# The hook can fire before the final hand-back is flushed, so wait (bounded)
# until the current round ends in a verdict; otherwise record no decision.
# The current round starts after the latest prompt (a `user` entry with string
# content), so an earlier round's verdict can never be reused.
transcript="$(jq -r '.agent_transcript_path // empty' <<< "$input")"
if [[ -z "${message//[[:space:]]/}" && -f "$transcript" ]]; then
  for attempt in $(seq 1 25); do
    message="$(jq -rs '
      . as $all
      | ([ range(0; length)
           | select($all[.].type == "user" and ($all[.].message.content | type) == "string") ]
         | last // -1) as $prompt
      | [ $all[($prompt + 1):][] | select(.type == "assistant") | .message.content[]?
          | select(.type != "thinking") ] | last // {}
      | if .type == "text" then .text
        elif .type == "tool_use" and .name == "SubagentHandback" then .input.message
        else empty end' "$transcript" 2>/dev/null || true)"
    [[ -n "${message//[[:space:]]/}" ]] && break
    sleep 0.2
  done
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
