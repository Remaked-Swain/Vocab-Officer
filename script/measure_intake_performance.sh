#!/usr/bin/env bash
# Release performance acceptance (targets: .claude/rules/intake-ocr.md).
#   measure_intake_performance.sh             run the suite
#   measure_intake_performance.sh --list      print the selected tests
#   measure_intake_performance.sh --self-test check discovery and result parsing
#
# Tests that call requirePerformanceTests() run only from the performance-build
# DerivedData path; they are discovered automatically. ACCEPTANCE_TESTS lists
# ordinary tests that also belong to the acceptance run.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Vocab.xcodeproj"
DERIVED_DATA="$ROOT_DIR/performance-build"
ACCEPTANCE_TESTS=(
  LearningCoordinatorTests/testPasteParserHandlesLargePastedTextWithHyphenatedTerms
  OCRVocabularyFormatterTests/testRecoversNoisyNumbersAndLooserRowAlignment
  OCRVocabularyFormatterTests/testHundredRowFixtureRecoversAtLeastNinetyEightRows
)

# Prints Class/testName for each test function in $1 whose own body calls
# requirePerformanceTests(). Every `func` line resets the current function, so
# the helper's definition or a non-test function is never credited to a test.
gated_tests_in_file() {
  awk -v class="$(basename "$1" .swift)" '
    /(^|[[:space:]])func[[:space:]]/ {
      current = ""
      if (match($0, /func test[A-Za-z0-9_]+[[:space:]]*\(/)) {
        name = substr($0, RSTART + 5, RLENGTH - 5); sub(/[[:space:]]*\($/, "", name); current = name
      }
      next
    }
    /requirePerformanceTests\(\)/ && current != "" { print class "/" current; current = "" }
  ' "$1"
}

discover_gated_tests() {
  local files file found=""
  files="$(git -C "$ROOT_DIR" grep -l 'requirePerformanceTests()' -- 'VocabTests/*.swift')" \
    || { echo "No performance-gated test files found." >&2; return 1; }
  while IFS= read -r file; do
    found+="$(gated_tests_in_file "$ROOT_DIR/$file")"$'\n'
  done <<< "$files"
  found="$(grep . <<< "$found" || true)"
  [[ -n "$found" ]] || { echo "No performance-gated tests discovered." >&2; return 1; }
  printf '%s\n' "$found"
}

selected_tests() {
  local test gated
  for test in "${ACCEPTANCE_TESTS[@]}"; do
    git -C "$ROOT_DIR" grep -q "func ${test#*/}(" -- "VocabTests/*/${test%%/*}.swift" \
      || { echo "Acceptance test not found: $test" >&2; return 1; }
    echo "$test"
  done
  gated="$(discover_gated_tests)" || return 1
  printf '%s\n' "$gated"
}

# Reads xcodebuild output; fails unless exactly $1 tests ran with none skipped.
verify_executed() {
  local expected="$1" summary executed skipped
  summary="$(grep -E 'Executed [0-9]+ tests?, with' | tail -1)"
  [[ -n "$summary" ]] || { echo "No XCTest summary found." >&2; return 1; }
  executed="$(sed -E 's/.*Executed ([0-9]+) tests?.*/\1/' <<< "$summary")"
  skipped=0
  [[ "$summary" =~ ([0-9]+)\ tests?\ skipped ]] && skipped="${BASH_REMATCH[1]}"
  if [[ "$executed" -ne "$expected" || "$skipped" -ne 0 ]]; then
    echo "Expected $expected executed and 0 skipped; got: $summary" >&2
    return 1
  fi
}

self_test() {
  local tests fixture
  tests="$(selected_tests)"
  [[ "$tests" == *"LearningCoordinatorTests/testGenerateSessionLargeFixtureP95MeetsTarget"* ]] \
    || { echo "self-test: known gated test not discovered" >&2; return 1; }

  # Only call sites count: neither an ungated test before the helper nor the
  # helper definition itself may be selected.
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/vocab-perf-fixture.XXXXXX")"
  cat > "$fixture/FixtureTests.swift" << 'SWIFT'
final class FixtureTests: XCTestCase {
    func testGated() throws {
        try requirePerformanceTests()
    }
    func testOrdinary() throws {
        XCTAssertTrue(true)
    }
    private func requirePerformanceTests() throws {
        guard Bundle.main.bundlePath.contains("/performance-build/") else { return }
    }
    func testAfterHelper() {}
}
SWIFT
  [[ "$(gated_tests_in_file "$fixture/FixtureTests.swift")" == "FixtureTests/testGated" ]] \
    || { rm -rf "$fixture"; echo "self-test: helper definition credited to a test" >&2; return 1; }
  rm -rf "$fixture"

  # A missing acceptance test must fail selection, not shrink the run.
  if ( ACCEPTANCE_TESTS=(LearningCoordinatorTests/testDoesNotExist); selected_tests ) > /dev/null 2>&1; then
    echo "self-test: missing acceptance test did not fail" >&2; return 1
  fi
  [[ "$(sort <<< "$tests" | uniq -d)" == "" ]] || { echo "self-test: duplicate selection" >&2; return 1; }
  printf "Test Suite 'All tests' passed.\n\t Executed 9 tests, with 0 failures (0 unexpected) in 1.0 seconds\n" \
    | verify_executed 9 || return 1
  ! printf '\t Executed 9 tests, with 2 tests skipped and 0 failures (0 unexpected)\n' \
    | verify_executed 9 2> /dev/null || { echo "self-test: skipped tests accepted" >&2; return 1; }
  ! printf '\t Executed 0 tests, with 0 failures (0 unexpected)\n' \
    | verify_executed 9 2> /dev/null || { echo "self-test: zero executed accepted" >&2; return 1; }
  echo "Performance script self-test passed ($(grep -c . <<< "$tests") tests selected)."
}

case "${1:-}" in
  --list) selected_tests; exit 0 ;;
  --self-test) self_test; exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--list | --self-test]" >&2; exit 2 ;;
esac

# Capture first: a failing process substitution would silently shrink the run.
selection="$(selected_tests)"
declare -a tests=() only_testing=()
while IFS= read -r test; do
  tests+=("$test")
  only_testing+=("-only-testing:VocabTests/$test")
done <<< "$selection"

log="$(mktemp "${TMPDIR:-/tmp}/vocab-performance.XXXXXX")"
trap 'rm -f "$log"' EXIT
echo "Measuring ${#tests[@]} performance acceptance tests (Release)..."
/usr/bin/time -lp xcodebuild \
  -project "$PROJECT" \
  -scheme Vocab \
  -destination "platform=macOS" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  test \
  "${only_testing[@]}" 2>&1 | tee "$log"
verify_executed "${#tests[@]}" < "$log"
echo "All ${#tests[@]} performance acceptance tests executed."
