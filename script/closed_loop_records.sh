#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX="$ROOT_DIR/Docs/ClosedLoop/index.json"

usage() {
  echo "usage: $0 validate | can-delete <record-id> <deletion-reason> | --self-test" >&2
  exit 2
}

[[ "$#" -ge 1 ]] || usage

run_self_test() {
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/closed-loop-records.XXXXXX")"
  trap 'rm -rf "$temp_dir"' EXIT INT TERM

  make_fixture() {
    local name="$1"
    local root="$temp_dir/$name"
    mkdir -p "$root/script" "$root/Docs/ClosedLoop/records"
    cp "$ROOT_DIR/script/closed_loop_records.sh" "$root/script/closed_loop_records.sh"
    chmod +x "$root/script/closed_loop_records.sh"
    printf '# CL-9999\n\n| Status | active |\n' > "$root/Docs/ClosedLoop/records/CL-9999-fixture.md"
    printf '{"records":[{"id":"CL-9999","type":"decision","status":"active","retentionClass":"audit","title":"Fixture","date":"2026-09-03","tags":[],"affectedPaths":[],"path":"Docs/ClosedLoop/records/CL-9999-fixture.md","references":[],"supersedes":[],"supersededBy":null,"retentionUntil":null,"protected":true,"unresolvedLimitations":[]}]}\n' > "$root/Docs/ClosedLoop/index.json"
    printf '| ID | Status | Record |\n| --- | --- | --- |\n| CL-9999 | active | [Fixture](records/CL-9999-fixture.md) |\n' > "$root/Docs/ClosedLoop/INDEX.md"
    echo "$root"
  }

  expect_failure() {
    local root="$1"
    if "$root/script/closed_loop_records.sh" validate >/dev/null 2>&1; then
      echo "record self-test expected failure: $root" >&2
      exit 1
    fi
  }

  local valid
  valid="$(make_fixture valid)"
  "$valid/script/closed_loop_records.sh" validate >/dev/null

  local duplicate_path
  duplicate_path="$(make_fixture duplicate-path)"
  printf '{"records":[{"id":"CL-9999","type":"decision","status":"active","retentionClass":"audit","title":"A","date":"2026-09-03","tags":[],"affectedPaths":[],"path":"Docs/ClosedLoop/records/CL-9999-fixture.md","references":[],"supersedes":[],"supersededBy":null,"retentionUntil":null,"protected":true,"unresolvedLimitations":[]},{"id":"CL-9998","type":"decision","status":"active","retentionClass":"audit","title":"B","date":"2026-09-03","tags":[],"affectedPaths":[],"path":"Docs/ClosedLoop/records/CL-9999-fixture.md","references":[],"supersedes":[],"supersededBy":null,"retentionUntil":null,"protected":true,"unresolvedLimitations":[]}]}\n' > "$duplicate_path/Docs/ClosedLoop/index.json"
  expect_failure "$duplicate_path"

  local duplicate_human
  duplicate_human="$(make_fixture duplicate-human)"
  printf '| CL-9999 | active | [Fixture](records/CL-9999-fixture.md) |\n' >> "$duplicate_human/Docs/ClosedLoop/INDEX.md"
  expect_failure "$duplicate_human"

  local human_only
  human_only="$(make_fixture human-only)"
  printf '| RUN-ORPHAN | completed | [Orphan](runs/orphan.md) |\n' >> "$human_only/Docs/ClosedLoop/INDEX.md"
  expect_failure "$human_only"

  local filename_mismatch
  filename_mismatch="$(make_fixture filename-mismatch)"
  mv "$filename_mismatch/Docs/ClosedLoop/records/CL-9999-fixture.md" "$filename_mismatch/Docs/ClosedLoop/records/CL-9998-fixture.md"
  sed -i '' 's/CL-9999-fixture/CL-9998-fixture/g' "$filename_mismatch/Docs/ClosedLoop/index.json" "$filename_mismatch/Docs/ClosedLoop/INDEX.md"
  expect_failure "$filename_mismatch"

  local orphan
  orphan="$(make_fixture orphan-file)"
  printf '# CL-9998\n\n| Status | active |\n' > "$orphan/Docs/ClosedLoop/records/CL-9998-orphan.md"
  expect_failure "$orphan"

  rm -rf "$temp_dir"
  trap - EXIT INT TERM
  echo "Closed-Loop record validator self-test passed."
}

if [[ "$1" == "--self-test" ]]; then
  [[ "$#" -eq 1 ]] || usage
  run_self_test
  exit 0
fi

case "$1" in
  validate)
    /usr/bin/ruby -rjson -rdate -e '
root, index, human_index = ARGV
data = JSON.parse(File.read(index))
human = File.read(human_index)
ids = {}
paths = {}
human_rows = Hash.new { |hash, key| hash[key] = [] }
human.each_line do |line|
  next unless line.start_with?("|")
  cells = line.split("|", -1).map(&:strip)
  id = cells[1]
  next unless id&.match?(/\A(?:CL|RUN)-[A-Za-z0-9._-]+\z/)
  human_rows[id] << line
end
allowed_status = %w[active in-review completed superseded archived deleted]
required = %w[id type status retentionClass title date tags affectedPaths path references supersedes supersededBy retentionUntil protected unresolvedLimitations]
data.fetch("records").each do |record|
  id = record.fetch("id")
  abort("duplicate record id: #{id}") if ids[id]
  path_value = record.fetch("path")
  abort("duplicate record path: #{path_value}") if paths[path_value]
  paths[path_value] = id
  missing = required.reject { |field| record.key?(field) }
  abort("missing metadata for #{id}: #{missing.join(", ")}") unless missing.empty?
  abort("invalid status for #{id}: #{record.fetch("status")}") unless allowed_status.include?(record.fetch("status"))
  ids[id] = true
  path = File.join(root, record.fetch("path"))
  status = record.fetch("status")
  rows = human_rows.fetch(id, [])
  abort("INDEX.md requires exactly one row for #{id}, found #{rows.count}") unless rows.count == 1
  if status == "deleted"
    abort("deleted record #{id} requires deletedAt and deletionReason") unless record["deletedAt"] && record["deletionReason"]
  else
    abort("missing record path: #{record.fetch("path")}") unless File.exist?(path)
    contents = File.read(path)
    markdown_status = contents[/\| Status \| ([^|]+) \|/, 1]
    abort("missing markdown status for #{id}") unless markdown_status
    abort("status drift for #{id}: json=#{status} markdown=#{markdown_status.strip}") unless markdown_status.strip == status
    if record.fetch("path").start_with?("Docs/ClosedLoop/records/")
      filename_id = File.basename(record.fetch("path"))[/\A(CL-\d{4,})-/, 1]
      abort("record filename ID mismatch for #{id}") unless filename_id == id
    end
    human_relative = record.fetch("path").delete_prefix("Docs/ClosedLoop/")
    linked = human.each_line.any? do |line|
      cells = line.split("|", -1).map(&:strip)
      line.start_with?("|") && cells[1] == id &&
        line.match?(/\]\(#{Regexp.escape(human_relative)}\)/)
    end
    abort("INDEX.md path mismatch for #{id}: #{human_relative}") unless linked
  end
  abort("INDEX.md status mismatch for #{id}") unless rows.first.match?(/\|\s*#{Regexp.escape(id)}\s*\|\s*#{Regexp.escape(status)}\s*\|/)
  if status == "archived"
    abort("archived record outside archive path: #{id}") unless record.fetch("path").start_with?("Docs/ClosedLoop/archive/")
  end
  if status == "superseded"
    abort("superseded record lacks replacement or retention date: #{id}") unless record["supersededBy"] && record["retentionUntil"]
  end
end
human_only = human_rows.keys - ids.keys
abort("INDEX.md rows missing from index.json: #{human_only.join(", ")}") unless human_only.empty?
indexed_paths = data.fetch("records")
  .reject { |record| record.fetch("status") == "deleted" }
  .map { |record| record.fetch("path") }
decision_files = Dir.glob(File.join(root, "Docs", "ClosedLoop", "records", "CL-*.md"))
  .map { |path| path.delete_prefix("#{root}/") }
orphans = decision_files - indexed_paths
abort("unindexed decision records: #{orphans.join(", ")}") unless orphans.empty?
data.fetch("records").each do |record|
  (record.fetch("references") + record.fetch("supersedes")).each do |reference|
    abort("unknown reference #{reference} from #{record.fetch("id")}") unless ids[reference]
  end
  replacement = record["supersededBy"]
  if replacement
    abort("unknown superseding record #{replacement}") unless ids[replacement]
    newer = data.fetch("records").find { |entry| entry.fetch("id") == replacement }
    abort("supersede link is not reciprocal: #{record.fetch("id")} -> #{replacement}") unless newer.fetch("supersedes").include?(record.fetch("id"))
  end
  record.fetch("supersedes").each do |older_id|
    older = data.fetch("records").find { |entry| entry.fetch("id") == older_id }
    abort("supersede link is not reciprocal: #{record.fetch("id")} supersedes #{older_id}") unless older["supersededBy"] == record.fetch("id")
  end
  record.fetch("partiallySupersedes", []).each do |link|
    older = data.fetch("records").find { |entry| entry.fetch("id") == link.fetch("id") }
    abort("unknown partial supersession #{link.fetch("id")} from #{record.fetch("id")}") unless older
    reciprocal = older.fetch("partiallySupersededBy", []).any? do |entry|
      entry["id"] == record.fetch("id") && entry["scope"] == link.fetch("scope")
    end
    abort("partial supersession link is not reciprocal: #{record.fetch("id")} -> #{link.fetch("id")}") unless reciprocal
  end
  record.fetch("partiallySupersededBy", []).each do |link|
    newer = data.fetch("records").find { |entry| entry.fetch("id") == link.fetch("id") }
    abort("unknown partial replacement #{link.fetch("id")} for #{record.fetch("id")}") unless newer
    reciprocal = newer.fetch("partiallySupersedes", []).any? do |entry|
      entry["id"] == record.fetch("id") && entry["scope"] == link.fetch("scope")
    end
    abort("partial replacement link is not reciprocal: #{record.fetch("id")} -> #{link.fetch("id")}") unless reciprocal
  end
end
puts "Closed-Loop index valid: #{ids.length} records"
' "$ROOT_DIR" "$INDEX" "$ROOT_DIR/Docs/ClosedLoop/INDEX.md"
    ;;
  can-delete)
    [[ "$#" -eq 3 ]] || usage
    /usr/bin/ruby -rjson -rdate -e '
index, id, reason = ARGV
records = JSON.parse(File.read(index)).fetch("records")
record = records.find { |entry| entry.fetch("id") == id }
abort("unknown record id: #{id}") unless record
abort("blocked: deletion reason required") if reason.strip.empty?
abort("blocked: #{id} status is #{record.fetch("status")}") unless %w[superseded archived].include?(record.fetch("status"))
abort("blocked: #{id} retention class is #{record.fetch("retentionClass")}") if %w[permanent audit].include?(record.fetch("retentionClass"))
abort("blocked: #{id} is protected") if record.fetch("protected")
abort("blocked: #{id} has unresolved limitations") unless record.fetch("unresolvedLimitations", []).empty?
until_date = record["retentionUntil"]
abort("blocked: #{id} lacks retention date") unless until_date
abort("blocked: #{id} retained until #{until_date}") if Date.parse(until_date) > Date.today
referrer = records.find { |entry| %w[active in-review].include?(entry.fetch("status")) && entry.fetch("references", []).include?(id) }
abort("blocked: #{id} is referenced by #{referrer.fetch("id")}") if referrer
puts "eligible for reviewed deletion: #{id}; create a deleted tombstone with reason: #{reason}"
' "$INDEX" "$2" "$3"
    ;;
  *)
    usage
    ;;
esac
