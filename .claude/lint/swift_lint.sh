#!/usr/bin/env bash
# Declarative Swift lint for Vocab. Rules live in swift.rules next to this
# script; this file only evaluates them.
#   swift_lint.sh               check the repository
#   swift_lint.sh --list        print rule ids and messages
#   swift_lint.sh --baseline ID rewrite ID's baseline from current matches
#   swift_lint.sh --self-test   prove every rule's example fails
set -euo pipefail

LINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${VOCAB_LINT_ROOT:-$(cd "$LINT_DIR/../.." && pwd)}"
RULES_FILE="${VOCAB_LINT_RULES:-$LINT_DIR/swift.rules}"
BASELINE_DIR="${VOCAB_LINT_BASELINES:-$LINT_DIR/baselines}"
DEFAULT_PATHS="Vocab VocabIOS VocabTests"

declare -a ids=() messages=() patterns=() paths=() allows=() baselines=() examples=()

die() { echo "swift lint: $*" >&2; exit 2; }

load_rules() {
  [[ -f "$RULES_FILE" ]] || die "rules file not found: $RULES_FILE"
  local line key value index=-1 number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^\[([a-z0-9-]+)\][[:space:]]*$ ]]; then
      index=$((index + 1))
      ids[index]="${BASH_REMATCH[1]}"
      messages[index]=""; patterns[index]=""; paths[index]="$DEFAULT_PATHS"
      allows[index]=""; baselines[index]=""; examples[index]=""
      continue
    fi
    [[ "$line" =~ ^([a-z]+)[[:space:]]*=[[:space:]]?(.*)$ ]] || die "line $number: expected 'key = value'"
    (( index >= 0 )) || die "line $number: setting before the first [rule-id]"
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    case "$key" in
      message) messages[index]="$value" ;;
      pattern) patterns[index]="$value" ;;
      paths) paths[index]="$value" ;;
      allow) allows[index]="$value" ;;
      baseline) baselines[index]="$value" ;;
      example) examples[index]="$value" ;;
      *) die "line $number: unknown key '$key'" ;;
    esac
  done < "$RULES_FILE"
  (( index >= 0 )) || die "no rules defined in $RULES_FILE"
  local i seen=" "
  for i in "${!ids[@]}"; do
    [[ -n "${messages[i]}" && -n "${patterns[i]}" ]] || die "[${ids[i]}] needs message and pattern"
    [[ "$seen" != *" ${ids[i]} "* ]] || die "duplicate rule id [${ids[i]}]"
    seen+="${ids[i]} "
  done
}

rule_index() {
  local i
  for i in "${!ids[@]}"; do
    [[ "${ids[i]}" == "$1" ]] && { echo "$i"; return 0; }
  done
  die "unknown rule '$1'"
}

# Matching lines as `path:content` (no line numbers), tracked + untracked.
matches_for() {
  local i="$1" target status=0 output
  local -a pathspecs=()
  for target in ${paths[i]}; do
    if [[ "$target" == *.swift || "$target" == *"*"* ]]; then
      pathspecs+=("$target")
    else
      pathspecs+=("$target/*.swift")
    fi
  done
  output="$(git -C "$ROOT_DIR" grep --untracked -I -P -e "${patterns[i]}" -- "${pathspecs[@]}" 2>&1)" || status=$?
  case "$status" in
    0) ;;
    1) return 0 ;;
    *) die "[${ids[i]}] search failed: $output" ;;
  esac
  if [[ -n "${allows[i]}" ]]; then
    output="$(grep -vF -- "${allows[i]}" <<< "$output" || true)"
  fi
  [[ -z "$output" ]] || LC_ALL=C sort <<< "$output"
}

check() {
  local i current expected failed=false
  for i in "${!ids[@]}"; do
    # Explicit: errexit is suppressed inside `check && ...`.
    current="$(matches_for "$i")" || exit 2
    if [[ -n "${baselines[i]}" ]]; then
      [[ -f "$BASELINE_DIR/${baselines[i]}" ]] || die "[${ids[i]}] baseline missing: ${baselines[i]}"
      expected="$(LC_ALL=C sort "$BASELINE_DIR/${baselines[i]}")"
      [[ "$current" == "$expected" ]] && continue
      printf 'Swift lint [%s]: %s\nBaseline drift (+ new, - removed; shrink the baseline when removing):\n' \
        "${ids[i]}" "${messages[i]}" >&2
      diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$current") | grep -E '^[+-][^+-]' >&2 || true
      failed=true
    elif [[ -n "$current" ]]; then
      printf 'Swift lint [%s]: %s\n%s\n' "${ids[i]}" "${messages[i]}" "$current" >&2
      failed=true
    fi
  done
  [[ "$failed" == false ]]
}

self_test() {
  local i target output
  # Global, not local: the EXIT trap runs after this function returns.
  temp="$(mktemp -d "${TMPDIR:-/tmp}/vocab-swift-lint.XXXXXX")"
  trap 'rm -rf "$temp"' EXIT
  git -C "$temp" init -q
  mkdir -p "$temp/baselines" "$temp/Vocab/Domain" "$temp/VocabIOS" "$temp/VocabTests"
  for i in "${!ids[@]}"; do
    [[ -z "${baselines[i]}" ]] || : > "$temp/baselines/${baselines[i]}"
  done
  run() { VOCAB_LINT_ROOT="$temp" VOCAB_LINT_RULES="$RULES_FILE" VOCAB_LINT_BASELINES="$temp/baselines" "$0" "$@"; }

  printf 'func valid(_ value: Int?) {\n    guard let value else { return }\n    for item in [value] { print(item) }\n}\n' \
    > "$temp/Vocab/Domain/Valid.swift"
  run > /dev/null || die "self-test: clean fixture failed"

  for i in "${!ids[@]}"; do
    [[ -n "${examples[i]}" ]] || die "self-test: [${ids[i]}] has no example"
    target="${paths[i]%% *}"
    [[ "$target" == *.swift || "$target" == *"*"* ]] && die "self-test: [${ids[i]}] first path must be a directory"
    mkdir -p "$temp/$target"
    printf '%s\n' "${examples[i]}" > "$temp/$target/Example.swift"
    if output="$(run 2>&1)"; then
      die "self-test: [${ids[i]}] example did not fail"
    fi
    [[ "$output" == *"[${ids[i]}]"* ]] || die "self-test: [${ids[i]}] not reported: $output"
    if [[ -n "${allows[i]}" ]]; then
      printf '%s // %s\n' "${examples[i]}" "${allows[i]}" > "$temp/$target/Example.swift"
      run > /dev/null 2>&1 || die "self-test: [${ids[i]}] allow marker not honored"
    fi
    rm -f "$temp/$target/Example.swift"
  done

  printf '[broken]\nmessage = x\npattern = (unclosed\nexample = x\n' > "$temp/broken.rules"
  VOCAB_LINT_ROOT="$temp" VOCAB_LINT_RULES="$temp/broken.rules" "$0" > /dev/null 2>&1 \
    && die "self-test: invalid pattern did not fail closed"
  printf '[no-pattern]\nmessage = x\n' > "$temp/broken.rules"
  VOCAB_LINT_ROOT="$temp" VOCAB_LINT_RULES="$temp/broken.rules" "$0" > /dev/null 2>&1 \
    && die "self-test: incomplete rule did not fail"
  echo "Swift lint self-test passed (${#ids[@]} rules)."
}

load_rules
case "${1:-}" in
  "") check && echo "Swift lint passed (${#ids[@]} rules)." ;;
  --list)
    for i in "${!ids[@]}"; do printf '%-26s %s\n' "${ids[i]}" "${messages[i]}"; done ;;
  --baseline)
    i="$(rule_index "${2:?rule id required}")"
    [[ -n "${baselines[i]}" ]] || die "[${ids[i]}] declares no baseline file"
    mkdir -p "$BASELINE_DIR"
    matches="$(matches_for "$i")" || exit 2
    printf '%s\n' "$matches" | grep . > "$BASELINE_DIR/${baselines[i]}" || : > "$BASELINE_DIR/${baselines[i]}"
    echo "Rewrote baselines/${baselines[i]} ($(grep -c . "$BASELINE_DIR/${baselines[i]}" || true) entries)." ;;
  --self-test) self_test ;;
  *) die "usage: $0 [--list | --baseline <rule-id> | --self-test]" ;;
esac
