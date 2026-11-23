#!/usr/bin/env bash
# Self-test for the Vocab Claude harness: settings, rg shim, style hook,
# audit binding, commit gate and verification selection.
set -euo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$HARNESS/.." && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vocab-harness.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT INT TERM

fail() { echo "harness self-test failed: $*" >&2; exit 1; }
expect_status() {
  local expected="$1" actual
  shift
  set +e
  "$@" > "$temp_dir/out" 2>&1
  actual=$?
  set -e
  [[ "$actual" -eq "$expected" ]] || fail "expected $expected, got $actual: $* :: $(cat "$temp_dir/out")"
}

for script in "$HARNESS"/hooks/*.sh "$HARNESS/bin/rg" "$HARNESS/skills/verify/select.sh"; do
  bash -n "$script" || fail "syntax: $script"
done
jq empty "$HARNESS/settings.json" || fail "settings.json is not valid JSON"
PATH="$HARNESS/bin:$PATH" rg --version > /dev/null || fail "rg shim cannot resolve ripgrep"

# Style hook: silent for non-Swift, blocking when the checker fails.
fake="$temp_dir/fake"
mkdir -p "$fake/script"
printf '#!/bin/bash\necho "violation"; exit 1\n' > "$fake/script/swift_style_check.sh"
chmod +x "$fake/script/swift_style_check.sh"
style_hook="$HARNESS/hooks/swift_style_after_edit.sh"
expect_status 0 env CLAUDE_PROJECT_DIR="$fake" bash -c "echo '{\"tool_input\":{\"file_path\":\"a.md\"}}' | '$style_hook'"
expect_status 2 env CLAUDE_PROJECT_DIR="$fake" bash -c "echo '{\"tool_input\":{\"file_path\":\"A.swift\"}}' | '$style_hook'"

# Audit binding and commit gate in a scratch repository.
repo="$temp_dir/repo"
mkdir -p "$repo/Vocab" "$repo/Docs"
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
gate() { echo "{\"tool_input\":{\"command\":\"$1\"}}" | CLAUDE_PROJECT_DIR="$repo" "$HARNESS/hooks/commit_gate.sh"; }
verdict() {
  jq -n --arg type "$1" --arg msg "$2" '{agent_type:$type, agent_id:"t", last_assistant_message:$msg}' \
    | CLAUDE_PROJECT_DIR="$repo" "$HARNESS/hooks/record_audit.sh"
}

echo "doc" > "$repo/Docs/a.md"
expect_status 0 gate "git commit -m docs"
echo "let a = 1" > "$repo/Vocab/A.swift"
expect_status 0 gate "git status"
expect_status 2 gate "git commit -m code"
expect_status 2 gate "git add -A && git -C . commit -m code"
verdict "general-purpose" "Decision: approve"
expect_status 2 gate "git commit -m code"
verdict "auditor" "**Decision:** approve"
expect_status 0 gate "git commit -m code"
git -C "$repo" add -A
expect_status 0 gate "git commit -m staged"
echo "let a = 2" > "$repo/Vocab/A.swift"
expect_status 2 gate "git commit -m changed"
verdict "auditor" "Decision: approve"
expect_status 0 gate "git commit -m reapproved"
verdict "auditor" $'Decision: reject\nDecision: approve'
expect_status 2 gate "git commit -m rejected"
[[ "$(wc -l < "$repo/.git/claude-audit/log.tsv")" -eq 3 ]] || fail "audit log should hold three auditor verdicts"

# Hand-back reports leave last_assistant_message empty; read the transcript.
transcript="$temp_dir/agent.jsonl"
jq -nc '{type:"assistant", message:{content:[{type:"text", text:"Reviewing."}]}}' > "$transcript"
jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"SubagentHandback",
  input:{message:"## Note\nDecision: approve\n## Findings\n- None"}}]}}' >> "$transcript"
jq -n --arg path "$transcript" '{agent_type:"auditor", agent_id:"t", last_assistant_message:"", agent_transcript_path:$path}' \
  | CLAUDE_PROJECT_DIR="$repo" "$HARNESS/hooks/record_audit.sh"
expect_status 0 gate "git commit -m handback"

# One approval covers a change split into several commits of the same tree.
echo "let b = 1" > "$repo/Vocab/B.swift"
verdict "auditor" "Decision: approve"
git -C "$repo" reset -q
git -C "$repo" add Docs
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m part1
expect_status 0 gate "git commit -m part2"
git -C "$repo" add Vocab/A.swift
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m part2
expect_status 0 gate "git commit -m part3"
chmod +x "$repo/Vocab/B.swift"
expect_status 2 gate "git commit -m mode-changed"

# A detected commit fails closed when approval cannot be verified.
expect_status 2 env CLAUDE_PROJECT_DIR="$temp_dir/not-a-repo" bash -c \
  "echo '{\"tool_input\":{\"command\":\"git commit -m x\"}}' | '$HARNESS/hooks/commit_gate.sh'"
expect_status 0 env CLAUDE_PROJECT_DIR="$temp_dir/not-a-repo" bash -c \
  "echo '{\"tool_input\":{\"command\":\"ls\"}}' | '$HARNESS/hooks/commit_gate.sh'"

# Verification selection.
select="$HARNESS/skills/verify/select.sh"
plan="$("$select" Vocab/Domain/StudyPolicies.swift)"
[[ "$plan" == *"-only-testing:VocabTests/StudyPoliciesTests"* && "$plan" != *"LearningCoordinatorTests"* ]] || fail "domain plan"
plan="$("$select" Vocab/Application/OCRVocabularyFormatter.swift)"
[[ "$plan" == *"LearningCoordinatorTests"* && "$plan" == *"OCRVocabularyFormatterTests"* ]] || fail "application plan"
plan="$("$select" Vocab/Data/Records.swift)"
[[ "$plan" != *"xcodebuild"* && "$plan" == *"Deferred"* ]] || fail "data plan must defer"
plan="$("$select" --final Vocab/Presentation/TodayIntakeView.swift)"
[[ "$plan" == *" build"* && "$plan" == *"Manual follow-up"* ]] || fail "final UI plan"
plan="$("$select" Vocab/Presentation/RootView.swift)"
[[ "$plan" == *"swift_style_check.sh"* && "$plan" != *"xcodebuild"* ]] || fail "UI plan"
plan="$("$select" .claude/settings.json)"
[[ "$plan" == *"self_test.sh"* ]] || fail "harness plan"
plan="$("$select" README.md)"
[[ "$plan" == *"none required"* ]] || fail "docs plan"
plan="$("$select" removed/tool.rb)"
[[ "$plan" == *"none required"* && "$plan" != *"Deferred"* ]] || fail "deleted non-app path must select nothing"
plan="$("$select" Vocab/Data/Removed.swift)"
[[ "$plan" == *"Deferred"* ]] || fail "deleted app path must still defer full XCTest"

[[ -f "$ROOT/script/legacy-concurrency-allowlist.txt" ]] || fail "concurrency allowlist missing"
echo "Harness self-test passed."
