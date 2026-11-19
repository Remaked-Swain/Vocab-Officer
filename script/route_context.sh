#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$ROOT_DIR/Docs/Rules/policy-registry.json"
SCENARIOS="$ROOT_DIR/Docs/Rules/routing-scenarios.json"
SCHEMA="$ROOT_DIR/Docs/Rules/schema.json"
SCHEMA_VALIDATOR="$ROOT_DIR/script/validate_policy_registry.rb"
LEDGER="$ROOT_DIR/Docs/ClosedLoop/index.json"
CATALOG="$ROOT_DIR/Docs/Rules/CATALOG.md"

fail_open() {
  echo "Context routing failed: $*" >&2
  echo "Fail open: read AGENTS.md and Docs/Rules/README.md, inspect Docs/Rules/CATALOG.md and the repository directly, and consult Docs/ClosedLoop/INDEX.md while uncertainty remains." >&2
  exit 3
}

usage() {
  cat >&2 <<'EOF'
usage:
  route_context.sh --intent <inspect|change> [--task <tag>]... [--path <repository-path>]... [--format <text|json>]
  route_context.sh --list-tasks
  route_context.sh --validate
  route_context.sh --self-test
EOF
  exit 2
}

route() {
  [[ -f "$REGISTRY" ]] || fail_open "missing policy registry"
  [[ -f "$LEDGER" ]] || fail_open "missing Closed-Loop ledger"
  /usr/bin/ruby -rjson -e '
root, registry_path, ledger_path, *arguments = ARGV
begin
  registry = JSON.parse(File.read(registry_path))
  ledger = JSON.parse(File.read(ledger_path))
rescue JSON::ParserError, Errno::ENOENT => error
  warn("Context routing failed: #{error.message}")
  warn("Fail open through AGENTS.md, Docs/Rules/README.md, Docs/Rules/CATALOG.md, direct inspection and Docs/ClosedLoop/INDEX.md.")
  exit(3)
end
tasks = []
paths = []
intent = nil
format = "text"
until arguments.empty?
  option = arguments.shift
  value = arguments.shift or abort("missing value for #{option}")
  case option
  when "--task" then tasks << value
  when "--path" then paths << value.delete_prefix("#{root}/")
  when "--intent" then intent = value
  when "--format" then format = value
  else abort("unknown option: #{option}")
  end
end
unless %w[inspect change].include?(intent) && %w[text json].include?(format)
  warn("Context routing failed: invalid intent or format")
  warn("Fail open through AGENTS.md, Docs/Rules/README.md, Docs/Rules/CATALOG.md, direct inspection and Docs/ClosedLoop/INDEX.md.")
  exit(3)
end
unknown = tasks - registry.fetch("tasks").keys
unless unknown.empty?
  warn("Context routing failed: unknown task tags: #{unknown.join(", ")}")
  warn("Fail open through AGENTS.md, Docs/Rules/README.md, Docs/Rules/CATALOG.md, direct inspection and Docs/ClosedLoop/INDEX.md.")
  exit(3)
end
rules = registry.fetch("rules")
rules_by_id = rules.to_h { |rule| [rule.fetch("id"), rule] }
reasons = Hash.new { |hash, key| hash[key] = [] }
direct = rules.select do |rule|
  task_hits = tasks & rule.fetch("tasks", [])
  path_hits = paths.select do |path|
    rule.fetch("pathPrefixes", []).any? { |prefix| path == prefix || path.start_with?(prefix) } ||
      rule.fetch("pathSuffixes", []).any? { |suffix| path.end_with?(suffix) }
  end
  task_hits.each { |task| reasons[rule.fetch("id")] << "task:#{task}" }
  path_hits.each { |path| reasons[rule.fetch("id")] << "path:#{path}" }
  !task_hits.empty? || !path_hits.empty?
end
required_rule_ids = direct.map { |rule| rule.fetch("id") }
recommended_rule_ids = []
historical_edges = []
queue = required_rule_ids.dup
until queue.empty?
  source_id = queue.shift
  rules_by_id.fetch(source_id).fetch("edges", []).each do |edge|
    target = edge.fetch("to")
    case edge.fetch("type")
    when "requires"
      unless required_rule_ids.include?(target)
        required_rule_ids << target
        queue << target
      end
      reasons[target] << "requires:#{source_id}"
    when "recommends"
      recommended_rule_ids << target unless required_rule_ids.include?(target) || recommended_rule_ids.include?(target)
      reasons[target] << "recommends:#{source_id}"
    when "historicalReference"
      historical_edges << [source_id, target]
    end
  end
end
recommended_queue = recommended_rule_ids.dup
recommended_visited = {}
until recommended_queue.empty?
  source_id = recommended_queue.shift
  next if recommended_visited[source_id]
  recommended_visited[source_id] = true
  rules_by_id.fetch(source_id).fetch("edges", []).each do |edge|
    target = edge.fetch("to")
    case edge.fetch("type")
    when "requires", "recommends"
      next if required_rule_ids.include?(target)
      unless recommended_rule_ids.include?(target)
        recommended_rule_ids << target
        recommended_queue << target
      end
      reasons[target] << "#{edge.fetch("type")}:#{source_id}"
    when "historicalReference"
      historical_edges << [source_id, target]
    end
  end
end
required = {}
recommended = {}
conditional = []
add_document = lambda do |collection, path, provenance|
  collection[path] ||= []
  collection[path] |= provenance
end
registry.fetch("alwaysRequired").each { |path| add_document.call(required, path, ["always"]) }
required_rule_ids.each do |id|
  rule = rules_by_id.fetch(id)
  provenance = reasons[id].empty? ? ["rule:#{id}"] : reasons[id]
  rule.fetch("required").each { |path| add_document.call(required, path, provenance) }
  rule.fetch("changeRequired", []).each { |path| add_document.call(required, path, provenance + ["change-intent"]) } if intent == "change"
  rule.fetch("recommended").each { |path| add_document.call(recommended, path, provenance) }
  rule.fetch("conditional").each do |entry|
    conditional << { "when" => entry.fetch("when"), "documents" => entry.fetch("documents"), "provenance" => provenance }
  end
end
recommended_rule_ids.each do |id|
  rule = rules_by_id.fetch(id)
  (rule.fetch("required") + rule.fetch("recommended")).each { |path| add_document.call(recommended, path, reasons[id]) }
end
historical_edges.each do |source, target|
  conditional << { "when" => "historical context from #{source} is explicitly required", "documents" => rules_by_id.fetch(target).fetch("required"), "provenance" => ["historicalReference:#{source}"] }
end
application_paths = paths.select do |path|
  registry.fetch("applicationPathPrefixes").any? { |prefix| path == prefix || path.start_with?(prefix) }
end
ledger.fetch("records").each do |record|
  next unless record.fetch("type") == "decision" && record.fetch("status") == "active" && record.fetch("retentionClass") == "permanent"
  matches = record.fetch("affectedPaths", []).select do |affected|
    next false if affected.end_with?("/") && affected.delete_suffix("/").split("/").length < 2
    application_paths.any? { |path| path == affected || (affected.end_with?("/") && path.start_with?(affected)) }
  end
  matches.each { |affected| add_document.call(recommended, record.fetch("path"), ["ledger-affected:#{affected}"]) }
end
required.each_key { |path| recommended.delete(path) }
warnings = []
application_path = !application_paths.empty?
if application_path && tasks.empty?
  warnings << { "code" => "SEMANTIC_TAG_MISSING", "message" => "Application paths were supplied without a semantic task tag; inspect the catalog and reroute after discovering the domain." }
end
paths.each do |path|
  if registry.fetch("broadSharedPaths").any? { |shared| path == shared || path.start_with?(shared) }
    warnings << { "code" => "BROAD_SHARED_PATH", "message" => "#{path} spans multiple product domains; path routing cannot establish complete context." }
  end
  matched_by_path = rules.any? do |rule|
    rule.fetch("pathPrefixes", []).any? { |prefix| path == prefix || path.start_with?(prefix) } ||
      rule.fetch("pathSuffixes", []).any? { |suffix| path.end_with?(suffix) }
  end
  warnings << { "code" => "UNCOVERED_PATH", "message" => "#{path} has no structural route; inspect repository ownership and the full policy index." } unless matched_by_path
end
warnings << { "code" => "NO_ROUTE_MATCH", "message" => "No policy route matched; use the catalog, direct inspection and full index." } if direct.empty?
selected_documents = required.keys + recommended.keys
registry.fetch("knownConflicts", []).each do |conflict|
  next unless (conflict.fetch("documents") - selected_documents).empty?
  warnings << { "code" => "POLICY_CONFLICT", "message" => conflict.fetch("message") }
end
unless warnings.empty?
  registry.fetch("fallbackDocuments").each { |path| add_document.call(recommended, path, ["fail-open-warning"]) unless required.key?(path) }
end
matched_for_workflow = (required_rule_ids + recommended_rule_ids).uniq.map { |id| rules_by_id.fetch(id) }
audit = intent == "change" && matched_for_workflow.any? { |rule| rule.fetch("audit") == "required" } ? "required" : "none"
order = { "none" => 0, "transient" => 1, "durable" => 2 }
evidence = intent == "change" ? (matched_for_workflow.map { |rule| rule.fetch("evidence") }.max_by { |value| order.fetch(value) } || "none") : "none"
result = {
  "intent" => intent,
  "matchedRules" => direct.map { |rule| rule.fetch("id") },
  "knownRequiredMinimum" => required.map { |path, provenance| { "path" => path, "provenance" => provenance } },
  "likelyRelevant" => recommended.map { |path, provenance| { "path" => path, "provenance" => provenance } },
  "conditional" => conditional,
  "warnings" => warnings,
  "auditor" => audit,
  "evidence" => evidence,
  "verification" => intent == "change" ? "./script/verify_changed.sh --plan #{paths.join(" ")}".rstrip : "none"
}
if format == "json"
  puts JSON.pretty_generate(result)
  exit
end
puts "Intent: #{intent}"
puts "Matched rules: #{result.fetch("matchedRules").empty? ? "(none)" : result.fetch("matchedRules").join(", ")}"
puts "Known-required minimum:"
result.fetch("knownRequiredMinimum").each { |item| puts "  #{item.fetch("path")} [#{item.fetch("provenance").join(", ")}]" }
puts "Likely relevant:"
result.fetch("likelyRelevant").empty? ? (puts "  (none)") : result.fetch("likelyRelevant").each { |item| puts "  #{item.fetch("path")} [#{item.fetch("provenance").join(", ")}]" }
puts "Conditional:"
result.fetch("conditional").empty? ? (puts "  (none)") : result.fetch("conditional").each { |item| puts "  #{item.fetch("when")}: #{item.fetch("documents").join(", ")}" }
puts "Warnings:"
warnings.empty? ? (puts "  (none)") : warnings.each { |warning| puts "  #{warning.fetch("code")}: #{warning.fetch("message")}" }
puts "Auditor: #{audit}"
puts "Evidence: #{evidence}"
puts "Verification: #{result.fetch("verification") }"
' "$ROOT_DIR" "$REGISTRY" "$LEDGER" "$@" || fail_open "router execution was unsuccessful"
}

validate() {
  [[ -f "$REGISTRY" && -f "$SCENARIOS" && -f "$SCHEMA" && -f "$SCHEMA_VALIDATOR" && -f "$LEDGER" && -f "$CATALOG" ]] || fail_open "routing inputs are missing"
  /usr/bin/ruby "$SCHEMA_VALIDATOR" "$SCHEMA" "$REGISTRY" >/dev/null
  /usr/bin/ruby -rjson -e '
root, registry_path, scenario_path, ledger_path, catalog_path = ARGV
registry = JSON.parse(File.read(registry_path))
scenarios = JSON.parse(File.read(scenario_path))
ledger = JSON.parse(File.read(ledger_path))
catalog = File.read(catalog_path)
abort("unsupported policy registry schema") unless registry.fetch("schemaVersion") == 1
abort("unsupported scenario schema") unless scenarios.fetch("schemaVersion") == 1
records = ledger.fetch("records").to_h { |record| [record.fetch("path"), record] }
ids = {}
validate_document = lambda do |path, tier|
  abort("missing #{tier} document: #{path}") unless File.file?(File.join(root, path))
  next unless path.start_with?("Docs/ClosedLoop/records/")
  record = records[path] or abort("unindexed routed record: #{path}")
  if %w[required recommended changeRequired alwaysRequired fallbackDocuments].include?(tier)
    abort("#{tier} record is not active or in-review: #{record.fetch("id")}") unless %w[active in-review].include?(record.fetch("status"))
  end
end
registry.fetch("alwaysRequired").each { |path| validate_document.call(path, "alwaysRequired") }
registry.fetch("fallbackDocuments").each { |path| validate_document.call(path, "fallbackDocuments") }
registry.fetch("tasks").each_key { |task| abort("catalog omits task #{task}") unless catalog.include?("`#{task}`") }
registry.fetch("rules").each do |rule|
  id = rule.fetch("id")
  abort("duplicate rule id: #{id}") if ids[id]
  ids[id] = rule
  rule.fetch("tasks", []).each { |task| abort("unknown task #{task} in #{id}") unless registry.fetch("tasks").key?(task) }
  %w[required recommended changeRequired].each do |tier|
    rule.fetch(tier, []).each { |path| validate_document.call(path, tier) }
  end
  rule.fetch("conditional").each { |entry| entry.fetch("documents").each { |path| validate_document.call(path, "conditional") } }
end
registry.fetch("knownConflicts").each do |conflict|
  abort("known conflict needs at least two documents") unless conflict.fetch("documents").length >= 2
  conflict.fetch("documents").each { |path| validate_document.call(path, "conflict") }
end
registry.fetch("rules").each do |rule|
  rule.fetch("edges").each do |edge|
    abort("unknown edge target #{edge.fetch("to")}") unless ids.key?(edge.fetch("to"))
    abort("invalid edge type #{edge.fetch("type")}") unless %w[requires recommends historicalReference].include?(edge.fetch("type"))
  end
end
visiting = {}
visited = {}
visit = lambda do |id|
  abort("requires cycle at #{id}") if visiting[id]
  return if visited[id]
  visiting[id] = true
  ids.fetch(id).fetch("edges").select { |edge| edge.fetch("type") == "requires" }.each { |edge| visit.call(edge.fetch("to")) }
  visiting.delete(id)
  visited[id] = true
end
ids.each_key { |id| visit.call(id) }
scenario_names = {}
covered_tasks = []
scenarios.fetch("scenarios").each do |scenario|
  name = scenario.fetch("name")
  abort("duplicate scenario name: #{name}") if scenario_names[name]
  scenario_names[name] = true
  abort("invalid scenario intent: #{name}") unless %w[inspect change].include?(scenario.fetch("intent"))
  scenario.fetch("tasks").each do |task|
    abort("scenario #{name} uses unknown task #{task}") unless registry.fetch("tasks").key?(task)
    covered_tasks << task
  end
  scenario.fetch("paths").each { |path| abort("scenario #{name} uses missing path #{path}") unless File.exist?(File.join(root, path)) }
  scenario.fetch("required").each { |path| validate_document.call(path, "scenario") }
  scenario.fetch("recommended", []).each { |path| validate_document.call(path, "scenario") }
  workflow = scenario.fetch("workflow")
  abort("invalid scenario auditor: #{name}") unless %w[required none].include?(workflow.fetch("auditor"))
  abort("invalid scenario evidence: #{name}") unless %w[durable transient none].include?(workflow.fetch("evidence"))
  scenario.fetch("warnings")
end
missing_tasks = registry.fetch("tasks").keys - covered_tasks.uniq
abort("tasks lack semantic scenarios: #{missing_tasks.join(", ")}") unless missing_tasks.empty?
routed_documents = registry.fetch("rules").flat_map do |rule|
  rule.fetch("required") + rule.fetch("recommended") + rule.fetch("changeRequired", []) +
    rule.fetch("conditional").flat_map { |entry| entry.fetch("documents") }
end
unrouted_decisions = ledger.fetch("records").select do |record|
  record.fetch("type") == "decision" && record.fetch("status") == "active" &&
    record.fetch("retentionClass") == "permanent" && !routed_documents.include?(record.fetch("path"))
end
abort("active permanent decisions lack a route: #{unrouted_decisions.map { |record| record.fetch("id") }.join(", ")}") unless unrouted_decisions.empty?
puts "Policy registry valid: #{ids.length} rules, #{scenarios.fetch("scenarios").length} semantic scenarios"
' "$ROOT_DIR" "$REGISTRY" "$SCENARIOS" "$LEDGER" "$CATALOG"
}

run_scenarios() {
  while IFS=$'\t' read -r name intent tasks paths required recommended warnings auditor evidence; do
    command=("$0" --intent "$intent" --format json)
    IFS=',' read -r -a task_items <<< "$tasks"
    for task in "${task_items[@]}"; do [[ -n "$task" && "$task" != "-" ]] && command+=(--task "$task"); done
    IFS=',' read -r -a path_items <<< "$paths"
    for path in "${path_items[@]}"; do [[ -n "$path" && "$path" != "-" ]] && command+=(--path "$path"); done
    output="$("${command[@]}")"
    printf '%s' "$output" | /usr/bin/ruby -rjson -e '
name, required, recommended, warnings, auditor, evidence = ARGV
result = JSON.parse(STDIN.read)
paths = result.fetch("knownRequiredMinimum").map { |item| item.fetch("path") }
required.split("\u001f").reject(&:empty?).each { |path| abort("#{name}: missing required #{path}") unless paths.include?(path) }
likely = result.fetch("likelyRelevant").map { |item| item.fetch("path") }
recommended.split("\u001f").reject { |value| value.empty? || value == "-" }.each { |path| abort("#{name}: missing recommended #{path}") unless likely.include?(path) }
codes = result.fetch("warnings").map { |item| item.fetch("code") }
warnings.split(",").reject { |value| value.empty? || value == "-" }.each { |code| abort("#{name}: missing warning #{code}") unless codes.include?(code) }
abort("#{name}: expected auditor #{auditor}, got #{result.fetch("auditor")}") unless result.fetch("auditor") == auditor
abort("#{name}: expected evidence #{evidence}, got #{result.fetch("evidence")}") unless result.fetch("evidence") == evidence
' "$name" "$required" "$recommended" "$warnings" "$auditor" "$evidence"
  done < <(/usr/bin/ruby -rjson -e '
JSON.parse(File.read(ARGV.fetch(0))).fetch("scenarios").each do |scenario|
  tasks = scenario.fetch("tasks").empty? ? "-" : scenario.fetch("tasks").join(",")
  paths = scenario.fetch("paths").empty? ? "-" : scenario.fetch("paths").join(",")
  recommended = scenario.fetch("recommended", []).empty? ? "-" : scenario.fetch("recommended").join("\u001f")
  warnings = scenario.fetch("warnings").empty? ? "-" : scenario.fetch("warnings").join(",")
  workflow = scenario.fetch("workflow")
  puts [scenario.fetch("name"), scenario.fetch("intent"), tasks, paths, scenario.fetch("required").join("\u001f"), recommended, warnings, workflow.fetch("auditor"), workflow.fetch("evidence")].join("\t")
end
' "$SCENARIOS")
}

case "${1:-}" in
  --list-tasks)
    [[ "$#" -eq 1 ]] || usage
    /usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0))).fetch("tasks").each { |tag, description| puts "#{tag}: #{description}" }' "$REGISTRY"
    ;;
  --validate)
    [[ "$#" -eq 1 ]] || usage
    validate
    ;;
  --self-test)
    [[ "$#" -eq 1 ]] || usage
    validate >/dev/null
    /usr/bin/ruby "$SCHEMA_VALIDATOR" "$SCHEMA" "$REGISTRY" --self-test >/dev/null
    run_scenarios
    error_file="$(mktemp "${TMPDIR:-/tmp}/vocab-route-error.XXXXXX")"
    if "$0" --intent inspect --task unknown-task > /dev/null 2>"$error_file"; then
      echo "Context router self-test expected an unknown task to fail open." >&2
      exit 1
    fi
    rg -q "Fail open" "$error_file"
    rm -f "$error_file"
    echo "Context router self-test passed."
    ;;
  --intent)
    route "$@"
    ;;
  *)
    usage
    ;;
esac
