#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Vocab.xcodeproj"
DERIVED_DATA="$ROOT_DIR/test-build"
PLAN_ONLY=false

if [[ "${1:-}" == "--self-test" ]]; then
  domain_plan="$("$0" --plan Vocab/Domain/StudyPolicies.swift)"
  [[ "$domain_plan" == *"-only-testing:VocabTests/StudyPoliciesTests"* ]]
  [[ "$domain_plan" != *"-only-testing:VocabTests/LearningCoordinatorTests"* ]]

  app_plan="$("$0" --plan Vocab/Application/LearningCoordinator.swift)"
  [[ "$app_plan" == *"-only-testing:VocabTests/StudyPoliciesTests"* ]]
  [[ "$app_plan" == *"-only-testing:VocabTests/LearningCoordinatorTests"* ]]

  backup_plan="$("$0" --plan Vocab/Infrastructure/BackupService.swift)"
  [[ "$backup_plan" == *"CODE_SIGNING_ALLOWED=NO test"* ]]
  [[ "$backup_plan" != *"-only-testing:"* ]]

  process_plan="$("$0" --plan Docs/ClosedLoop/README.md script/verify_changed.sh)"
  [[ "$process_plan" == *"bash -n"* ]]
  [[ "$process_plan" != *"xcodebuild"* ]]

  echo "Verification selection self-test passed."
  exit 0
fi

if [[ "${1:-}" == "--plan" ]]; then
  PLAN_ONLY=true
  shift
fi

declare -a changed_files=()
inferred_changes=false
if [[ "$#" -gt 0 ]]; then
  changed_files=("$@")
else
  inferred_changes=true
  while IFS= read -r file; do
    [[ -n "$file" ]] && changed_files+=("$file")
  done < <(
    cd "$ROOT_DIR"
    {
      git diff --name-only --cached 2>/dev/null || true
      git diff --name-only 2>/dev/null || true
      git ls-files --others --exclude-standard 2>/dev/null || true
    } | LC_ALL=C sort -u
  )
fi

if [[ "${#changed_files[@]}" -eq 0 ]]; then
  echo "No changed files detected; no verification selected."
  exit 0
fi

run_domain=false
run_application=false
run_full=false
run_build=false
run_shell=false
manual_ui=false
no_baseline=false

if "$inferred_changes" && ! (cd "$ROOT_DIR" && git rev-parse --verify HEAD >/dev/null 2>&1); then
  no_baseline=true
  run_full=true
fi

for file in "${changed_files[@]}"; do
  file="${file#"$ROOT_DIR"/}"
  case "$file" in
    Docs/*|.gitignore|.codex/*)
      ;;
    script/*.sh)
      run_shell=true
      ;;
    Vocab/Domain/*|Vocab/Infrastructure/TextNormalizer.swift|VocabTests/Domain/*)
      run_domain=true
      ;;
    Vocab/Application/*)
      run_application=true
      run_domain=true
      ;;
    Vocab/Data/*|Vocab/Infrastructure/BackupService.swift)
      run_full=true
      ;;
    VocabTests/Application/*)
      run_application=true
      ;;
    Vocab/Presentation/*)
      run_build=true
      manual_ui=true
      ;;
    Vocab/App/*)
      run_build=true
      ;;
    Vocab.xcodeproj/*|Vocab/Infrastructure/*|VocabTests/*)
      run_full=true
      ;;
    *)
      run_full=true
      ;;
  esac
done

if "$run_full"; then
  run_domain=false
  run_application=false
  run_build=false
fi

declare -a actions=()
if "$run_shell"; then
  actions+=("bash -n \"$ROOT_DIR/script/verify_changed.sh\"")
  if [[ -f "$ROOT_DIR/script/closed_loop_records.sh" ]]; then
    actions+=("bash -n \"$ROOT_DIR/script/closed_loop_records.sh\"")
  fi
  if [[ -f "$ROOT_DIR/script/build_and_run.sh" ]]; then
    actions+=("bash -n \"$ROOT_DIR/script/build_and_run.sh\"")
  fi
  actions+=("\"$ROOT_DIR/script/verify_changed.sh\" --self-test")
fi
if "$run_full"; then
  actions+=("xcodebuild -project \"$PROJECT\" -scheme Vocab -configuration Debug -derivedDataPath \"$DERIVED_DATA\" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test")
elif "$run_domain" || "$run_application"; then
  command="xcodebuild -project \"$PROJECT\" -scheme Vocab -configuration Debug -derivedDataPath \"$DERIVED_DATA\" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test"
  "$run_domain" && command+=" -only-testing:VocabTests/StudyPoliciesTests"
  "$run_application" && command+=" -only-testing:VocabTests/LearningCoordinatorTests"
  actions+=("$command")
fi
if "$run_build"; then
  actions+=("xcodebuild -project \"$PROJECT\" -scheme Vocab -configuration Debug -derivedDataPath \"$ROOT_DIR/build\" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build")
fi

echo "Changed files:"
printf '  %s\n' "${changed_files[@]}"
if "$no_baseline"; then
  echo "No baseline commit exists; inferred changes require full XCTest fallback."
fi
if [[ "${#actions[@]}" -eq 0 ]]; then
  echo "Selected verification: records or documentation only; no executable verification required."
  exit 0
fi

echo "Selected verification:"
printf '  %s\n' "${actions[@]}"
if "$manual_ui"; then
  echo "Manual follow-up required: exercise the changed presentation flow after the build."
fi
if "$PLAN_ONLY"; then
  exit 0
fi

for action in "${actions[@]}"; do
  (cd "$ROOT_DIR" && eval "$action")
done
