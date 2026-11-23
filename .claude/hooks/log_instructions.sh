#!/usr/bin/env bash
# InstructionsLoaded: record which rule file loaded and why, so the value of
# each rule can be measured instead of assumed. Local only (.git/claude-metrics).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input="$(cat)"
root="$(vocab_root)"
dir="$(git -C "$root" rev-parse --absolute-git-dir)/claude-metrics"
mkdir -p "$dir"
jq -r --arg root "$root/" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  [ $ts,
    (.session_id // "-"),
    ((.file_path // "-") | ltrimstr($root)),
    (.load_reason // "-"),
    ((.trigger_file_path // "-") | ltrimstr($root)) ] | @tsv' <<< "$input" >> "$dir/instructions.tsv"
