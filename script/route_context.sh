#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/Docs/Rules/context-routes.json"
LEDGER="$ROOT_DIR/Docs/ClosedLoop/index.json"

usage() {
  cat >&2 <<'EOF'
usage:
  route_context.sh --intent <inspect|change> [--task <tag>]... [--path <repository-path>]...
  route_context.sh --list-tasks
  route_context.sh --validate
  route_context.sh --self-test
EOF
  exit 2
}

route() {
  /usr/bin/ruby -rjson -e '
root, manifest_path, ledger_path, *arguments = ARGV
manifest = JSON.parse(File.read(manifest_path))
ledger = JSON.parse(File.read(ledger_path))
tasks = []
paths = []
intent = nil
until arguments.empty?
  option = arguments.shift
  value = arguments.shift or abort("missing value for #{option}")
  case option
  when "--task" then tasks << value
  when "--path" then paths << value.delete_prefix("#{root}/")
  when "--intent" then intent = value
  else abort("unknown option: #{option}")
  end
end
abort("--intent must be inspect or change") unless %w[inspect change].include?(intent)

unknown = tasks - manifest.fetch("tasks").keys
abort("unknown task tags: #{unknown.join(", ")}") unless unknown.empty?

matched = manifest.fetch("rules").select do |rule|
  task_match = !(tasks & rule.fetch("tasks", [])).empty?
  path_match = paths.any? do |path|
    rule.fetch("pathPrefixes", []).any? { |prefix| path == prefix || path.start_with?(prefix) } ||
      rule.fetch("pathSuffixes", []).any? { |suffix| path.end_with?(suffix) }
  end
  task_match || path_match
end

documents = (manifest.fetch("alwaysLoad") + matched.flat_map { |rule| rule.fetch("documents") }).uniq
audit = intent == "change" && matched.any? { |rule| rule.fetch("audit", "none") == "required" } ? "required" : "none"
evidence_order = { "none" => 0, "transient" => 1, "durable" => 2 }
evidence = if intent == "change"
  matched.map { |rule| rule.fetch("evidence", "none") }
    .max_by { |value| evidence_order.fetch(value) } || "none"
else
  "none"
end

puts "Intent: #{intent}"
puts "Matched routes:"
if matched.empty?
  puts "  (none; read the always-load contract only)"
else
  matched.each { |rule| puts "  #{rule.fetch("id")}" }
end
puts "Context documents:"
documents.each { |path| puts "  #{path}" }
puts "Auditor: #{audit}"
puts "Evidence: #{evidence}"
verification = if intent == "change"
  "./script/verify_changed.sh --plan#{paths.map { |path| " #{path}" }.join}"
else
  "none"
end
puts "Verification: #{verification}"
' "$ROOT_DIR" "$MANIFEST" "$LEDGER" "$@"
}

validate() {
  /usr/bin/ruby -rjson -e '
root, manifest_path, ledger_path = ARGV
manifest = JSON.parse(File.read(manifest_path))
abort("unsupported context route schema") unless manifest.fetch("schemaVersion") == 1
ledger = JSON.parse(File.read(ledger_path))
indexed = ledger.fetch("records").to_h { |record| [record.fetch("path"), record] }
indexed_by_id = ledger.fetch("records").to_h { |record| [record.fetch("id"), record] }
ids = {}
routed_record_ids = []
manifest.fetch("rules").each do |rule|
  id = rule.fetch("id")
  abort("duplicate route id: #{id}") if ids[id]
  ids[id] = true
  rule.fetch("tasks", []).each do |task|
    abort("unknown route task #{task} in #{id}") unless manifest.fetch("tasks").key?(task)
  end
  rule.fetch("documents").each do |path|
    abort("missing routed document: #{path}") unless File.file?(File.join(root, path))
    next unless path.start_with?("Docs/ClosedLoop/records/")
    record = indexed[path] or abort("routed record is not indexed: #{path}")
    abort("routed record is not active: #{record.fetch("id")}") unless record.fetch("status") == "active"
    routed_record_ids << record.fetch("id")
  end
end
manifest.fetch("requiredActiveRecords").each do |id|
  record = indexed_by_id[id] or abort("required route record is not indexed: #{id}")
  abort("required route record is not active: #{id}") unless record.fetch("status") == "active"
  abort("active load rule is not routed: #{id}") unless routed_record_ids.include?(id)
end
manifest.fetch("alwaysLoad").each do |path|
  abort("missing always-load document: #{path}") unless File.file?(File.join(root, path))
end
puts "Context route manifest valid: #{ids.length} routes"
' "$ROOT_DIR" "$MANIFEST" "$LEDGER"
}

case "${1:-}" in
  --list-tasks)
    [[ "$#" -eq 1 ]] || usage
    /usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0))).fetch("tasks").each { |tag, description| puts "#{tag}: #{description}" }' "$MANIFEST"
    ;;
  --validate)
    [[ "$#" -eq 1 ]] || usage
    validate
    ;;
  --self-test)
    [[ "$#" -eq 1 ]] || usage
    validate >/dev/null
    harness="$(route --intent change --task harness --path script/route_context.sh)"
    [[ "$harness" == *"CL-0037-context-routing-harness.md"* ]]
    [[ "$harness" == *"Auditor: required"* ]]
    [[ "$harness" == *"Evidence: durable"* ]]
    cloud="$(route --intent change --task cloudkit-bootstrap --path Vocab/App/VocabApp.swift)"
    [[ "$cloud" == *"Docs/iCloudIOSSyncPlan.md"* ]]
    [[ "$cloud" == *"Docs/SwiftStyleGuide.md"* ]]
    read_only="$(route --intent inspect --task correction)"
    [[ "$read_only" == *"CL-0010-parenthesized-comma-meaning-tracking.md"* ]]
    [[ "$read_only" == *"Context documents:"$'\n'"  AGENTS.md"* ]]
    [[ "$read_only" == *"Auditor: none"* ]]
    [[ "$read_only" == *"Evidence: none"* ]]
    [[ "$read_only" == *"Verification: none"* ]]
    echo "Context router self-test passed."
    ;;
  --intent)
    route "$@"
    ;;
  *)
    usage
    ;;
esac
