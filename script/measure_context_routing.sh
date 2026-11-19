#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTER="$ROOT_DIR/script/route_context.sh"
REGISTRY="$ROOT_DIR/Docs/Rules/policy-registry.json"

measure_case() {
  local name="$1"
  shift
  "$ROUTER" "$@" --format json | /usr/bin/ruby -rjson -e '
name, root, registry_path = ARGV
result = JSON.parse(STDIN.read)
registry = JSON.parse(File.read(registry_path))
universe = registry.fetch("alwaysRequired") + registry.fetch("fallbackDocuments")
registry.fetch("rules").each do |rule|
  universe.concat(rule.fetch("required"))
  universe.concat(rule.fetch("changeRequired", []))
  universe.concat(rule.fetch("recommended"))
  rule.fetch("conditional").each { |condition| universe.concat(condition.fetch("documents")) }
end
selected = result.fetch("knownRequiredMinimum").map { |item| item.fetch("path") } +
  result.fetch("likelyRelevant").map { |item| item.fetch("path") }
size = lambda do |paths|
  paths.uniq.sum do |path|
    absolute = File.join(root, path)
    File.file?(absolute) ? File.size(absolute) : 0
  end
end
universe_bytes = size.call(universe)
selected_bytes = size.call(selected)
ratio = universe_bytes.zero? ? 0 : (selected_bytes * 100.0 / universe_bytes)
puts [name, selected.uniq.length, selected_bytes, universe.uniq.length, universe_bytes, format("%.1f%%", ratio)].join("\t")
' "$name" "$ROOT_DIR" "$REGISTRY"
}

printf 'case\tselected_docs\tselected_bytes\tpolicy_docs\tpolicy_bytes\tselected_ratio\n'
measure_case "path-only-mastery" --intent inspect --path Vocab/Presentation/MasteredView.swift
measure_case "compound-study" --intent change --task mastery --task multiple-choice --path Vocab/Domain/StudyPolicies.swift
measure_case "cloudkit" --intent change --task cloudkit-reconciliation --task cloudkit-authority --path Vocab/App/VocabCloudSnapshotSyncService.swift
measure_case "harness" --intent change --task harness --path script/route_context.sh --path Docs/Rules/policy-registry.json
printf 'Byte counts are a reproducible context-size proxy, not tokenizer-exact token counts. Required documents are never budget-pruned.\n'
