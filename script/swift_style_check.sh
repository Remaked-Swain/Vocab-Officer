#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RG_BIN="rg"

run_check() {
  local root="$1"
  local failed=false
  local -a production_roots=()
  local -a all_roots=()

  command -v "$RG_BIN" >/dev/null 2>&1 || {
    echo "Swift style check cannot run: '$RG_BIN' is unavailable." >&2
    return 2
  }
  [[ -d "$root/Vocab" ]] && production_roots+=("$root/Vocab")
  [[ -d "$root/VocabIOS" ]] && production_roots+=("$root/VocabIOS")
  all_roots=("${production_roots[@]}")
  [[ -d "$root/VocabTests" ]] && all_roots+=("$root/VocabTests")
  [[ "${#all_roots[@]}" -gt 0 ]] || return 0

  check_rule() {
    local label="$1"
    local pattern="$2"
    local scope="$3"
    local allowed_marker="${4:-}"
    local -a roots=()
    local matches
    local status
    local filtered=""

    if [[ "$scope" == "all" ]]; then
      roots=("${all_roots[@]}")
    else
      roots=("${production_roots[@]}")
    fi
    [[ "${#roots[@]}" -gt 0 ]] || return 0

    set +e
    matches="$("$RG_BIN" -n --glob '*.swift' "$pattern" "${roots[@]}" 2>&1)"
    status=$?
    set -e
    case "$status" in
      0) ;;
      1) return 0 ;;
      *)
        printf 'Swift style check failed while evaluating %s:\n%s\n' "$label" "$matches" >&2
        return 2
        ;;
    esac

    while IFS= read -r line; do
      if [[ -z "$allowed_marker" || "$line" != *"$allowed_marker"* ]]; then
        filtered+="${filtered:+$'\n'}$line"
      fi
    done <<< "$matches"
    if [[ -n "$filtered" ]]; then
      printf 'Swift style violation: %s\n%s\n' "$label" "$filtered" >&2
      failed=true
    fi
  }

  check_rule 'use for-in instead of forEach for imperative iteration' '\.forEach[[:space:]]*\{' all
  check_rule 'do not force a throwing operation with try!' 'try![[:space:]]' production
  check_rule 'do not force-cast with as!' 'as![[:space:]]' production
  check_rule 'fatalError requires an audited irrecoverable-bootstrap marker' 'fatalError[[:space:]]*\(' production 'swift-style: allow(fatalError)'
  check_rule 'do not terminate production flows with preconditionFailure' 'preconditionFailure[[:space:]]*\(' production
  check_rule 'use actor isolation instead of DispatchQueue.main.async' 'DispatchQueue\.main\.async' all

  [[ "$failed" == false ]]
}

if [[ "${1:-}" == "--self-test" ]]; then
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vocab-swift-style.XXXXXX")"
  trap 'rm -rf "$temp_dir"' EXIT INT TERM
  mkdir -p "$temp_dir/Vocab" "$temp_dir/VocabIOS" "$temp_dir/VocabTests" "$temp_dir/script"
  cp "$0" "$temp_dir/script/swift_style_check.sh"
  chmod +x "$temp_dir/script/swift_style_check.sh"

  printf 'func valid(_ value: Int?) { guard let value else { return }; for item in [value] { print(item) } }\n' > "$temp_dir/Vocab/Valid.swift"
  "$temp_dir/script/swift_style_check.sh" >/dev/null

  expect_failure() {
    local path="$1"
    local source="$2"
    local expected="$3"
    local output
    rm -f "$temp_dir/Vocab/Invalid.swift" "$temp_dir/VocabIOS/Invalid.swift" "$temp_dir/VocabTests/Invalid.swift"
    printf '%s\n' "$source" > "$temp_dir/$path/Invalid.swift"
    if output="$("$temp_dir/script/swift_style_check.sh" 2>&1)"; then
      echo "Swift style self-test expected '$expected' fixture to fail." >&2
      exit 1
    fi
    [[ "$output" == *"$expected"* ]] || {
      echo "Swift style self-test did not report '$expected'." >&2
      exit 1
    }
  }

  expect_failure VocabTests 'func invalid(_ values: [Int]) { values.forEach { print($0) } }' 'for-in'
  expect_failure Vocab 'func invalid() { _ = try! throwingCall() }' 'try!'
  expect_failure VocabIOS 'func invalid(_ value: Any) { _ = value as! Int }' 'force-cast'
  expect_failure Vocab 'func invalid() { fatalError("stop") }' 'fatalError requires'
  expect_failure Vocab 'func invalid() { preconditionFailure("stop") }' 'preconditionFailure'
  expect_failure VocabTests 'func invalid() { DispatchQueue.main.async {} }' 'actor isolation'

  rm -f "$temp_dir/Vocab/Invalid.swift" "$temp_dir/VocabIOS/Invalid.swift" "$temp_dir/VocabTests/Invalid.swift"
  printf 'func allowedBootstrapFailure() { fatalError("stop") } // swift-style: allow(fatalError)\n' > "$temp_dir/Vocab/Allowed.swift"
  "$temp_dir/script/swift_style_check.sh" >/dev/null

  if PATH="/usr/bin:/bin" "$temp_dir/script/swift_style_check.sh" >/dev/null 2>&1; then
    echo 'Swift style self-test expected a missing search tool to fail closed.' >&2
    exit 1
  fi

  mkdir -p "$temp_dir/failing-bin"
  printf '#!/bin/sh\nexit 2\n' > "$temp_dir/failing-bin/rg"
  chmod +x "$temp_dir/failing-bin/rg"
  if PATH="$temp_dir/failing-bin:/usr/bin:/bin" "$temp_dir/script/swift_style_check.sh" >/dev/null 2>&1; then
    echo 'Swift style self-test expected a search execution error to fail closed.' >&2
    exit 1
  fi

  echo 'Swift style checker self-test passed.'
  exit 0
fi

[[ "$#" -eq 0 ]] || {
  echo "usage: $0 [--self-test]" >&2
  exit 2
}

run_check "$ROOT_DIR"
echo 'Swift style check passed.'
