#!/usr/bin/env bash
# Maps changed paths to the smallest meaningful verification.
#   select.sh [--run] [--final] [path...]   (no paths: infer from Git)
# Full XCTest and platform builds are selected only with --final.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROJECT="$ROOT_DIR/Vocab.xcodeproj"
XCTEST="xcodebuild -project \"$PROJECT\" -scheme Vocab -configuration Debug -derivedDataPath \"$ROOT_DIR/test-build\" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test"
RUN=false
FINAL=false

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --run) RUN=true ;;
    --final) FINAL=true ;;
    *) echo "usage: $0 [--run] [--final] [path...]" >&2; exit 2 ;;
  esac
  shift
done

declare -a files=()
if [[ "$#" -gt 0 ]]; then
  files=("$@")
else
  source "$ROOT_DIR/.claude/hooks/lib.sh"
  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(vocab_changed_paths "$ROOT_DIR")
fi
[[ "${#files[@]}" -gt 0 ]] || { echo "No changed files; nothing to verify."; exit 0; }

full=false; build=false; manual_ui=false; style=false; style_self=false
shell=false; harness=false; perf_self=false
declare -a test_classes=()
add_test() {
  local existing
  for existing in "${test_classes[@]+"${test_classes[@]}"}"; do
    [[ "$existing" == "$1" ]] && return 0
  done
  test_classes+=("$1")
}

for file in "${files[@]}"; do
  file="${file#"$ROOT_DIR"/}"
  # Removing a file outside the app targets and harness needs no tests.
  if [[ ! -e "$ROOT_DIR/$file" ]]; then
    case "$file" in
      Vocab/*|VocabIOS/*|VocabTests/*|Vocab.xcodeproj/*|.claude/*|CLAUDE.md) ;;
      *) continue ;;
    esac
  fi
  case "$file" in
    Vocab/Domain/*|Vocab/Infrastructure/TextNormalizer.swift|VocabTests/Domain/*)
      add_test StudyPoliciesTests ;;
    Vocab/Data/*|Vocab/Presentation/MasteredView.swift|Vocab.xcodeproj/*|Vocab/Infrastructure/*)
      full=true ;;
    Vocab/Application/VocabMutationAuthority.swift|Vocab/Application/VocabHydrationStatus.swift|\
    Vocab/Application/VocabBootstrapTokenStore.swift|Vocab/Application/VocabImportedChanges.swift|\
    Vocab/Application/VocabImportHistory.swift|Vocab/Application/VocabFullAuditReceipt.swift|\
    Vocab/Application/VocabCloudReconciler.swift|Vocab/Application/VocabCloudReconciliationWorker.swift)
      # Sync code under Application/ is covered by the sync test classes.
      add_test VocabCloudReconciliationTests; add_test VocabImportHistoryTests
      add_test AuthoringCapabilityTests ;;
    Vocab/Application/VocabRecordScrubbing.swift)
      add_test LearningCoordinatorTests; add_test VocabCloudReconciliationTests ;;
    Vocab/Application/*)
      add_test StudyPoliciesTests; add_test LearningCoordinatorTests ;;
    VocabTests/Application/*)
      add_test LearningCoordinatorTests ;;
    Vocab/Presentation/*|VocabIOS/*)
      build=true; manual_ui=true ;;
    Vocab/App/*)
      build=true ;;
    VocabTests/*)
      full=true ;;
    .claude/lint/*)
      harness=true; style=true; style_self=true ;;
    script/measure_intake_performance.sh)
      shell=true; perf_self=true ;;
    script/*.sh)
      shell=true ;;
    CLAUDE.md|.claude/*)
      harness=true ;;
    README.md|.gitignore|*.md)
      ;;
    *)
      full=true ;;
  esac
  # A changed source or test file also selects its own same-named test class.
  if [[ "$file" == *.swift ]]; then
    style=true
    name="$(basename "$file" .swift)"
    name="${name%Tests}"
    if [[ -n "$(find "$ROOT_DIR/VocabTests" -name "${name}Tests.swift" -print -quit 2>/dev/null)" ]]; then
      add_test "${name}Tests"
    fi
  fi
done

declare -a actions=()
"$shell" && actions+=("for f in \"$ROOT_DIR\"/script/*.sh; do bash -n \"\$f\"; done")
"$perf_self" && actions+=("\"$ROOT_DIR/script/measure_intake_performance.sh\" --self-test")
"$style_self" && actions+=("\"$ROOT_DIR/.claude/lint/swift_lint.sh\" --self-test")
"$style" && actions+=("\"$ROOT_DIR/.claude/lint/swift_lint.sh\"")
"$harness" && actions+=("\"$ROOT_DIR/.claude/hooks/self_test.sh\"")
if "$full" && "$FINAL"; then
  actions+=("$XCTEST")
elif [[ "${#test_classes[@]}" -gt 0 ]]; then
  command="$XCTEST"
  for test_class in "${test_classes[@]}"; do
    command+=" -only-testing:VocabTests/$test_class"
  done
  actions+=("$command")
fi
if "$build" && "$FINAL"; then
  actions+=("xcodebuild -project \"$PROJECT\" -scheme Vocab -configuration Debug -derivedDataPath \"$ROOT_DIR/build\" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build")
fi

echo "Changed files:"
printf '  %s\n' "${files[@]}"
if [[ "${#actions[@]}" -eq 0 ]]; then
  echo "Selected verification: none required now."
else
  echo "Selected verification:"
  printf '  %s\n' "${actions[@]}"
fi
if ! "$FINAL" && { "$full" || "$build"; }; then
  echo "Deferred: full XCTest/platform build runs with --final after the stage, or earlier only with user approval."
fi
"$manual_ui" && echo "Manual follow-up: exercise the changed presentation flow after the build."
"$RUN" || exit 0

for action in "${actions[@]+"${actions[@]}"}"; do
  (cd "$ROOT_DIR" && eval "$action")
done
