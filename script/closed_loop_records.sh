#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX="$ROOT_DIR/Docs/ClosedLoop/index.json"

usage() {
  echo "usage: $0 validate | can-delete <record-id> <deletion-reason>" >&2
  exit 2
}

[[ "$#" -ge 1 ]] || usage

case "$1" in
  validate)
    /usr/bin/ruby -rjson -rdate -e '
root, index, human_index = ARGV
data = JSON.parse(File.read(index))
human = File.read(human_index)
ids = {}
allowed_status = %w[active in-review completed superseded archived deleted]
required = %w[id type status retentionClass title date tags affectedPaths path references supersedes supersededBy retentionUntil protected unresolvedLimitations]
data.fetch("records").each do |record|
  id = record.fetch("id")
  abort("duplicate record id: #{id}") if ids[id]
  missing = required.reject { |field| record.key?(field) }
  abort("missing metadata for #{id}: #{missing.join(", ")}") unless missing.empty?
  abort("invalid status for #{id}: #{record.fetch("status")}") unless allowed_status.include?(record.fetch("status"))
  ids[id] = true
  path = File.join(root, record.fetch("path"))
  status = record.fetch("status")
  if status == "deleted"
    abort("deleted record #{id} requires deletedAt and deletionReason") unless record["deletedAt"] && record["deletionReason"]
  else
    abort("missing record path: #{record.fetch("path")}") unless File.exist?(path)
    contents = File.read(path)
    markdown_status = contents[/\| Status \| ([^|]+) \|/, 1]
    abort("missing markdown status for #{id}") unless markdown_status
    abort("status drift for #{id}: json=#{status} markdown=#{markdown_status.strip}") unless markdown_status.strip == status
  end
  abort("INDEX.md missing status row for #{id}") unless human.match?(/\|\s*#{Regexp.escape(id)}\s*\|\s*#{Regexp.escape(status)}\s*\|/)
  if status == "archived"
    abort("archived record outside archive path: #{id}") unless record.fetch("path").start_with?("Docs/ClosedLoop/archive/")
  end
  if status == "superseded"
    abort("superseded record lacks replacement or retention date: #{id}") unless record["supersededBy"] && record["retentionUntil"]
  end
end
data.fetch("records").each do |record|
  (record.fetch("references") + record.fetch("supersedes")).each do |reference|
    abort("unknown reference #{reference} from #{record.fetch("id")}") unless ids[reference]
  end
  replacement = record["supersededBy"]
  abort("unknown superseding record #{replacement}") if replacement && !ids[replacement]
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
