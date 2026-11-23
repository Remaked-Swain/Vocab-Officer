#!/usr/bin/env bash
# Self-test for the Vocab Claude harness: settings, lint engine and hook,
# rule-usage logging, audit binding, commit gate and verification selection.
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

for script in "$HARNESS"/hooks/*.sh "$HARNESS"/lint/*.sh "$HARNESS/skills/verify/select.sh"; do
  bash -n "$script" || fail "syntax: $script"
done
jq empty "$HARNESS/settings.json" || fail "settings.json is not valid JSON"
"$HARNESS/lint/swift_lint.sh" --self-test > /dev/null || fail "lint engine self-test"

# Every path-scoped rule file declares paths that still match something.
for rule in "$HARNESS"/rules/*.md; do
  while IFS= read -r glob; do
    [[ -n "$(git -C "$ROOT" ls-files -- ":(glob)$glob")" ]] || fail "$(basename "$rule"): stale path '$glob'"
  done < <(awk '/^---$/{n++; next} n==1 && /^  - "/{gsub(/^  - "|"$/, ""); print}' "$rule")
done

# Lint hook: silent for unrelated files, blocking when the lint fails.
fake="$temp_dir/fake"
mkdir -p "$fake/.claude/lint"
printf '#!/bin/bash\necho "violation"; exit 1\n' > "$fake/.claude/lint/swift_lint.sh"
chmod +x "$fake/.claude/lint/swift_lint.sh"
lint_hook="$HARNESS/hooks/lint_after_edit.sh"
expect_status 0 env CLAUDE_PROJECT_DIR="$fake" bash -c "echo '{\"tool_input\":{\"file_path\":\"a.md\"}}' | '$lint_hook'"
expect_status 2 env CLAUDE_PROJECT_DIR="$fake" bash -c "echo '{\"tool_input\":{\"file_path\":\"A.swift\"}}' | '$lint_hook'"
expect_status 2 env CLAUDE_PROJECT_DIR="$fake" bash -c "echo '{\"tool_input\":{\"file_path\":\"/x/.claude/lint/swift.rules\"}}' | '$lint_hook'"

# Audit binding and commit gate in a scratch repository.
repo="$temp_dir/repo"
mkdir -p "$repo/Vocab" "$repo/Docs"
git -C "$repo" init -q
# The gate lints Swift at commit, so the scratch repo carries the real rules
# with empty baselines; committing them keeps them out of later diffs.
mkdir -p "$repo/.claude/lint/baselines"
cp "$HARNESS/lint/swift_lint.sh" "$HARNESS/lint/swift.rules" "$repo/.claude/lint/"
for baseline in "$HARNESS"/lint/baselines/*; do : > "$repo/.claude/lint/baselines/$(basename "$baseline")"; done
git -C "$repo" add .claude
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m base
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

# A transcript whose final hand-back is not flushed yet must not reuse an
# older verdict: the last action is a tool call, so no decision is recorded.
jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"SubagentHandback",
  input:{message:"Decision: approve"}}]}}' > "$transcript"
jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"Bash", input:{command:"git diff"}}]}}' >> "$transcript"
jq -n --arg path "$transcript" '{agent_type:"auditor", agent_id:"t", last_assistant_message:"", agent_transcript_path:$path}' \
  | CLAUDE_PROJECT_DIR="$repo" "$HARNESS/hooks/record_audit.sh"
expect_status 2 gate "git commit -m unflushed"
[[ "$(tail -1 "$repo/.git/claude-audit/log.tsv" | cut -f3)" == "none" ]] || fail "unflushed verdict should record none"

# A re-review prompt with no reply flushed yet must not reuse the previous
# round's approval.
jq -nc '{type:"user", message:{content:"Review this change."}}' > "$transcript"
jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"SubagentHandback",
  input:{message:"Decision: approve"}}]}}' >> "$transcript"
jq -nc '{type:"user", message:{content:[{type:"tool_result", content:"ok"}]}}' >> "$transcript"
jq -nc '{type:"user", message:{content:"Re-review: the worktree changed."}}' >> "$transcript"
jq -n --arg path "$transcript" '{agent_type:"auditor", agent_id:"t", last_assistant_message:"", agent_transcript_path:$path}' \
  | CLAUDE_PROJECT_DIR="$repo" "$HARNESS/hooks/record_audit.sh"
expect_status 2 gate "git commit -m stale-round"
[[ "$(tail -1 "$repo/.git/claude-audit/log.tsv" | cut -f3)" == "none" ]] || fail "previous round verdict was reused"

# Once the current round's hand-back is flushed, it is used.
jq -nc '{type:"assistant", message:{content:[{type:"tool_use", name:"SubagentHandback",
  input:{message:"Decision: approve"}}]}}' >> "$transcript"
jq -n --arg path "$transcript" '{agent_type:"auditor", agent_id:"t", last_assistant_message:"", agent_transcript_path:$path}' \
  | CLAUDE_PROJECT_DIR="$repo" "$HARNESS/hooks/record_audit.sh"
expect_status 0 gate "git commit -m current-round"

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

# Lint runs at commit even with a matching approval (e.g. Swift from checkout).
chmod -x "$repo/Vocab/B.swift"
echo 'func f(_ v: [Int]) { v.forEach { print($0) } }' > "$repo/Vocab/C.swift"
verdict "auditor" "Decision: approve"
expect_status 2 gate "git commit -m lint-violation"
grep -q 'no-foreach' "$temp_dir/out" || fail "commit-time lint did not report the rule"
rm "$repo/Vocab/C.swift"

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
[[ "$plan" == *"swift_lint.sh"* && "$plan" != *"xcodebuild"* ]] || fail "UI plan"
plan="$("$select" .claude/lint/swift.rules)"
[[ "$plan" == *"swift_lint.sh\" --self-test"* && "$plan" == *"self_test.sh"* ]] || fail "lint rules plan"
plan="$("$select" .claude/settings.json)"
[[ "$plan" == *"self_test.sh"* ]] || fail "harness plan"
plan="$("$select" README.md)"
[[ "$plan" == *"none required"* ]] || fail "docs plan"
plan="$("$select" removed/tool.rb)"
[[ "$plan" == *"none required"* && "$plan" != *"Deferred"* ]] || fail "deleted non-app path must select nothing"
plan="$("$select" .claude/hooks/removed.sh)"
[[ "$plan" == *"self_test.sh"* ]] || fail "deleted harness path must run the harness self-test"
plan="$("$select" Vocab/Data/Removed.swift)"
[[ "$plan" == *"Deferred"* ]] || fail "deleted app path must still defer full XCTest"

# Rule-usage logging writes one local TSV row per loaded instruction file.
jq -n --arg file "$repo/.claude/rules/swift.md" --arg trigger "$repo/Vocab/A.swift" \
  '{session_id:"s1", file_path:$file, load_reason:"path_glob_match", trigger_file_path:$trigger}' \
  | CLAUDE_PROJECT_DIR="$repo" "$HARNESS/hooks/log_instructions.sh"
row="$(tail -1 "$repo/.git/claude-metrics/instructions.tsv")"
[[ "$row" == *$'\ts1\t.claude/rules/swift.md\tpath_glob_match\tVocab/A.swift' ]] || fail "instruction log row: $row"

echo "Harness self-test passed."
