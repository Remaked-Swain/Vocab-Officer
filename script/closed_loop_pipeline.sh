#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_ROOT="${CLOSED_LOOP_STATE_DIR:-$ROOT_DIR/.git/closed-loop-pipeline}"
PROJECT_ROOT="$ROOT_DIR"
RECORD_VALIDATOR="$ROOT_DIR/script/closed_loop_records.sh"
LOCK_WAIT_SECONDS="${CLOSED_LOOP_LOCK_WAIT_SECONDS:-5}"

usage() {
  cat >&2 <<'EOF'
usage:
  closed_loop_pipeline.sh start <run-id> [transient|durable]
  closed_loop_pipeline.sh register-role <run-id> <Main|Auditor> <actor-id> <handoff-token>
  closed_loop_pipeline.sh submit <run-id> Main <actor-id> <artifact>
  closed_loop_pipeline.sh review <run-id> Auditor <actor-id> <approve|reject> <artifact>
  closed_loop_pipeline.sh close <run-id> Main <actor-id> <close-artifact>
  closed_loop_pipeline.sh status <run-id>
  closed_loop_pipeline.sh --self-test
EOF
  exit 2
}

die() {
  echo "closed-loop pipeline: $*" >&2
  exit 1
}

validate_run_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid run id: $1"
}

with_lock() {
  local run_id="$1"
  shift
  local lock_root="$STATE_ROOT/locks"
  local lock_dir="$lock_root/$run_id.lock"
  local deadline=$((SECONDS + LOCK_WAIT_SECONDS))

  mkdir -p "$lock_root"
  until mkdir "$lock_dir" 2>/dev/null; do
    (( SECONDS >= deadline )) && die "timed out waiting for concurrent run lock: $run_id"
    sleep 0.05
  done
  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT INT TERM
  "$@"
  rmdir "$lock_dir"
  trap - EXIT INT TERM
}

mutate() {
  local action="$1"
  shift
  /usr/bin/ruby -rjson -rdigest -rtempfile -rfileutils -rtime -ropen3 -e '
state_root, project_root, validator, action, run_id, *args = ARGV
state_dir = File.join(state_root, "runs")
state_path = File.join(state_dir, "#{run_id}.json")

def fail!(message)
  abort("closed-loop pipeline: #{message}")
end

def actor!(value, role)
  fail!("#{role} identity must not be empty") if value.nil? || value.strip.empty?
  value
end

def artifact!(path, role)
  fail!("#{role} artifact path must not be empty") if path.nil? || path.strip.empty?
  absolute = File.expand_path(path)
  fail!("#{role} artifact is missing or not a file: #{path}") unless File.file?(absolute)
  fail!("#{role} artifact is empty: #{path}") unless File.size?(absolute)
  { "role" => role, "path" => absolute, "sha256" => Digest::SHA256.file(absolute).hexdigest }
end

def chain_sha256(previous_chain, artifact, order, decision = nil)
  Digest::SHA256.hexdigest([
    previous_chain || "GENESIS",
    order,
    artifact.fetch("role"),
    artifact.fetch("sha256"),
    decision || artifact["decision"] || "",
    artifact["worktreeSha256"] || ""
  ].join(":"))
end

def migrate_state!(state)
  version = state.fetch("schemaVersion")
  return state if version == 5
  fail!("unsupported state schema: #{version}") unless version == 4

  previous_chain = nil
  state.fetch("artifacts").each_with_index do |artifact, index|
    artifact["chainSha256"] = chain_sha256(previous_chain, artifact, index + 1)
    previous_chain = artifact.fetch("chainSha256")
  end
  state["latestChainSha256"] = previous_chain
  state["schemaVersion"] = 5
  state["migrations"] ||= []
  state["migrations"] << {
    "fromSchemaVersion" => 4,
    "toSchemaVersion" => 5,
    "migratedAt" => Time.now.utc.iso8601(6),
    "reason" => "bind decisions and reviewed worktree hashes into every chain link"
  }
  state
end

def worktree_sha256!(project_root)
  root, status = Open3.capture2("git", "-C", project_root, "rev-parse", "--show-toplevel")
  fail!("canonical project root is not a Git worktree") unless status.success?
  fail!("Git root differs from canonical project root") unless File.realpath(root.strip) == File.realpath(project_root)

  clean_git_env = { "GIT_EXTERNAL_DIFF" => nil, "GIT_DIFF_OPTS" => nil }
  diff, diff_status = Open3.capture2(
    clean_git_env,
    "git", "-C", project_root, "diff", "--no-ext-diff", "--no-textconv",
    "--binary", "--full-index", "HEAD", "--"
  )
  fail!("cannot read tracked worktree diff") unless diff_status.success?
  untracked, untracked_status = Open3.capture2("git", "-C", project_root, "ls-files", "--others", "--exclude-standard", "-z")
  fail!("cannot read untracked files") unless untracked_status.success?
  digest = Digest::SHA256.new
  digest.update(diff)
  untracked.split("\0").reject(&:empty?).sort.each do |relative|
    absolute = File.join(project_root, relative)
    fail!("untracked review file disappeared: #{relative}") unless File.file?(absolute)
    digest.update("\0#{relative}\0")
    digest.update(Digest::SHA256.file(absolute).digest)
  end
  digest.hexdigest
end

def load_state(path)
  migrate_state!(JSON.parse(File.read(path)))
rescue Errno::ENOENT
  fail!("run does not exist")
rescue JSON::ParserError => error
  fail!("invalid state: #{error.message}")
end

def expect_current!(state, role, stage)
  fail!("wrong role: expected #{state.fetch("currentRole")}, received #{role}") unless state.fetch("currentRole") == role
  fail!("wrong operation: expected #{state.fetch("currentStage")}, received #{stage}") unless state.fetch("currentStage") == stage
end

def validate_handoff!(state, token)
  expected = state.fetch("handoffToken")
  fail!("stale or wrong handoff token") unless token == expected
  return if expected == "GENESIS" && state.fetch("artifacts").empty?

  predecessor = state.fetch("artifacts").last
  fail!("handoff state has no predecessor artifact") unless predecessor
  path = predecessor.fetch("path")
  fail!("predecessor artifact is missing at registration") unless File.file?(path)
  current = Digest::SHA256.file(path).hexdigest
  fail!("predecessor artifact changed after submission") unless current == predecessor.fetch("sha256") && current == token
end

def active_registration!(state, role, actor_id, stage)
  expect_current!(state, role, stage)
  fail!("#{role} is not registered") unless state.fetch("phase") == "active"
  registration = state.fetch("registrations").last
  fail!("active registration role mismatch") unless registration.fetch("role") == role
  fail!("#{role} identity changed; expected #{registration.fetch("actorId")}") unless registration.fetch("actorId") == actor_id
  registration
end

def save_atomic!(state_dir, state_path, state)
  FileUtils.mkdir_p(state_dir)
  temp = Tempfile.new(["closed-loop-", ".json"], state_dir)
  begin
    temp.write(JSON.pretty_generate(state) + "\n")
    temp.flush
    temp.fsync
    temp.close
    File.rename(temp.path, state_path)
  ensure
    temp.close! unless temp.closed?
    File.unlink(temp.path) if File.exist?(temp.path)
  end
end

def append_artifact!(state, artifact, registration, decision = nil)
  order = state.fetch("artifacts").length + 1
  artifact.merge!({
    "order" => order,
    "actorId" => registration.fetch("actorId"),
    "registrationOrder" => registration.fetch("order"),
    "previousSha256" => state["latestArtifactSha256"],
    "chainSha256" => chain_sha256(state["latestChainSha256"], artifact, order, decision),
    "recordedAt" => Time.now.utc.iso8601(6)
  })
  artifact["decision"] = decision if decision
  state.fetch("artifacts") << artifact
  state["latestArtifactSha256"] = artifact.fetch("sha256")
  state["latestChainSha256"] = artifact.fetch("chainSha256")
  state["handoffToken"] = artifact.fetch("sha256")
end

def open_stage!(state, role, stage)
  state["currentRole"] = role
  state["currentStage"] = stage
  state["phase"] = "awaiting-registration"
end

def canonical_record!(path, project_root)
  records_dir = File.realpath(File.join(project_root, "Docs", "ClosedLoop", "records"))
  absolute = File.realpath(path)
  fail!("durable Main artifact must be directly under Docs/ClosedLoop/records") unless File.dirname(absolute) == records_dir
  basename = File.basename(absolute)
  match = basename.match(/\A(CL-\d{4,})-[A-Za-z0-9][A-Za-z0-9._-]*\.md\z/)
  fail!("durable Main artifact must match CL-*.md") unless match
  [absolute, match[1]]
rescue Errno::ENOENT
  fail!("durable Main artifact or records directory is missing")
end

def validate_record_ledger!(artifact_path, project_root, validator)
  absolute, record_id = canonical_record!(artifact_path, project_root)
  relative = absolute.delete_prefix("#{File.realpath(project_root)}/")
  human_relative = relative.delete_prefix("Docs/ClosedLoop/")
  human = File.read(File.join(project_root, "Docs", "ClosedLoop", "INDEX.md"))
  linked = human.each_line.any? do |line|
    cells = line.split("|", -1).map(&:strip)
    line.start_with?("|") && cells[1] == record_id && line.match?(/\]\(#{Regexp.escape(human_relative)}\)/)
  end
  fail!("INDEX.md does not link #{record_id} to #{human_relative}") unless linked
  data = JSON.parse(File.read(File.join(project_root, "Docs", "ClosedLoop", "index.json")))
  record = data.fetch("records").find { |item| item["id"] == record_id }
  fail!("index.json does not register #{record_id}") unless record
  fail!("index.json path mismatch for #{record_id}") unless record["path"] == relative
  valid = File.file?(validator) && File.executable?(validator) &&
    Dir.chdir(project_root) { system(validator, "validate", out: File::NULL, err: File::NULL) }
  fail!("closed-loop record validation failed") unless valid
rescue JSON::ParserError, KeyError => error
  fail!("invalid durable record ledger: #{error.message}")
end

case action
when "start"
  mode = args.fetch(0, "transient")
  fail!("evidence mode must be transient or durable") unless %w[transient durable].include?(mode)
  fail!("durable run id must start with RUN-") if mode == "durable" && !run_id.start_with?("RUN-")
  fail!("run already exists: #{run_id}") if File.exist?(state_path)
  completed_path = File.join(state_root, "completed", "#{run_id}.json")
  fail!("completed run id cannot be reused: #{run_id}") if File.exist?(completed_path)
  state = {
    "schemaVersion" => 5,
    "runId" => run_id,
    "evidenceMode" => mode,
    "currentRole" => "Main",
    "currentStage" => "main-submit",
    "phase" => "awaiting-registration",
    "handoffToken" => "GENESIS",
    "rejectionCount" => 0,
    "agentPolicy" => "main-plus-single-auditor",
    "roleIdentities" => {},
    "registrations" => [],
    "artifacts" => [],
    "latestArtifactSha256" => nil,
    "latestChainSha256" => nil
  }
  save_atomic!(state_dir, state_path, state)
  puts("started #{run_id} (#{mode}); activate Main with handoff token GENESIS")
when "register-role"
  role, actor_id, token = args
  fail!("invalid role: #{role}") unless %w[Main Auditor].include?(role)
  state = load_state(state_path)
  fail!("wrong role or future registration: expected #{state.fetch("currentRole")}, received #{role}") unless state.fetch("currentRole") == role
  fail!("#{role} is already registered") unless state.fetch("phase") == "awaiting-registration"
  actor_id = actor!(actor_id, role)
  validate_handoff!(state, token)
  identities = state.fetch("roleIdentities")
  other_role = role == "Main" ? "Auditor" : "Main"
  if identities[other_role] == actor_id
    fail!("#{role} identity must differ from #{other_role}")
  end
  fail!("#{role} identity changed; expected #{identities.fetch(role)}") if identities.key?(role) && identities.fetch(role) != actor_id
  first_registration = !identities.key?(role)
  identities[role] ||= actor_id
  registration = {
    "order" => state.fetch("registrations").length + 1,
    "role" => role,
    "actorId" => actor_id,
    "registeredAt" => Time.now.utc.iso8601(6),
    "handoffToken" => token,
    "kind" => first_registration ? "registered" : "reactivated"
  }
  state.fetch("registrations") << registration
  state["phase"] = "active"
  save_atomic!(state_dir, state_path, state)
  puts("#{registration.fetch("kind")} #{role} as order #{registration.fetch("order")}")
when "submit"
  role, actor_id, artifact_path = args
  fail!("submit role must be Main") unless role == "Main"
  state = load_state(state_path)
  registration = active_registration!(state, role, actor!(actor_id, role), "main-submit")
  artifact = artifact!(artifact_path, role)
  canonical_record!(artifact_path, project_root) if state.fetch("evidenceMode") == "durable"
  append_artifact!(state, artifact, registration)
  open_stage!(state, "Auditor", "auditor-review")
  save_atomic!(state_dir, state_path, state)
  puts("accepted Main artifact; activate Auditor with handoff token #{state.fetch("handoffToken")}")
when "review"
  role, actor_id, decision, artifact_path = args
  fail!("review role must be Auditor") unless role == "Auditor"
  fail!("review decision must be approve or reject") unless %w[approve reject].include?(decision)
  state = load_state(state_path)
  registration = active_registration!(state, role, actor!(actor_id, role), "auditor-review")
  artifact = artifact!(artifact_path, role)
  if decision == "approve" && state.fetch("evidenceMode") == "durable"
    audits_dir = File.join(project_root, "Docs", "ClosedLoop", "audits")
    absolute = File.realpath(artifact.fetch("path"))
    fail!("durable approval artifact must be directly under Docs/ClosedLoop/audits") unless File.dirname(absolute) == File.realpath(audits_dir)
    expected_name = "#{run_id}-audit.md"
    fail!("durable approval artifact must be named #{expected_name}") unless File.basename(absolute) == expected_name
  end
  artifact["worktreeSha256"] = worktree_sha256!(project_root) if decision == "approve"
  append_artifact!(state, artifact, registration, decision)
  if decision == "reject"
    state["rejectionCount"] += 1
    open_stage!(state, "Main", "main-submit")
  else
    open_stage!(state, "Main", "main-close")
  end
  save_atomic!(state_dir, state_path, state)
  puts("#{decision} recorded; activate Main with handoff token #{state.fetch("handoffToken")}")
when "close"
  role, actor_id, artifact_path = args
  fail!("close role must be Main") unless role == "Main"
  state = load_state(state_path)
  registration = active_registration!(state, role, actor!(actor_id, role), "main-close")
  approval_index = state.fetch("artifacts").rindex { |item| item["role"] == "Auditor" && item["decision"] == "approve" }
  fail!("Auditor approval is required before close") unless approval_index
  approved_main = state.fetch("artifacts")[0...approval_index].reverse.find { |item| item["role"] == "Main" }
  fail!("approved Main artifact is missing") unless approved_main
  unchanged = File.file?(approved_main.fetch("path")) &&
    Digest::SHA256.file(approved_main.fetch("path")).hexdigest == approved_main.fetch("sha256")
  fail!("approved Main artifact changed after review") unless unchanged
  approval = state.fetch("artifacts").fetch(approval_index)
  approval_unchanged = File.file?(approval.fetch("path")) &&
    Digest::SHA256.file(approval.fetch("path")).hexdigest == approval.fetch("sha256")
  fail!("Auditor approval artifact changed after review") unless approval_unchanged
  fail!("reviewed worktree changed after Auditor approval") unless
    worktree_sha256!(project_root) == approval.fetch("worktreeSha256")
  validate_record_ledger!(approved_main.fetch("path"), project_root, validator) if state.fetch("evidenceMode") == "durable"
  append_artifact!(state, artifact!(artifact_path, role), registration)
  if state.fetch("evidenceMode") == "durable"
    completed_dir = File.join(state_root, "completed")
    FileUtils.mkdir_p(completed_dir)
    completed_path = File.join(completed_dir, "#{run_id}.json")
    fail!("completed run evidence already exists: #{run_id}") if File.exist?(completed_path)
    save_atomic!(completed_dir, completed_path, state)
  end
  File.unlink(state_path)
  suffix = state.fetch("evidenceMode") == "durable" ? "; durable ledger validated" : ""
  puts("closed #{run_id} after Auditor approval#{suffix}")
when "status"
  puts(JSON.pretty_generate(load_state(state_path)))
else
  fail!("unknown action: #{action}")
end
' "$STATE_ROOT" "$PROJECT_ROOT" "$RECORD_VALIDATOR" "$action" "$@"
}

run_self_test() {
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/closed-loop-pipeline.XXXXXX")"
  trap 'rm -rf "$temp_dir"' EXIT INT TERM
  local state_dir="$temp_dir/state"
  local artifacts="$temp_dir/artifacts"
  local record="$ROOT_DIR/Docs/ClosedLoop/records/CL-0001-vocab-mvp-implementation.md"
  local durable_audit="$ROOT_DIR/Docs/ClosedLoop/audits/RUN-SELF-TEST-audit.md"
  local worktree_probe="$ROOT_DIR/.closed-loop-self-test-probe"
  mkdir -p "$artifacts"
  printf 'main output\n' > "$artifacts/main.txt"
  printf 'auditor review\n' > "$artifacts/auditor.txt"
  printf 'main close\n' > "$artifacts/close.txt"
  : > "$artifacts/empty.txt"

  run() {
    CLOSED_LOOP_STATE_DIR="$state_dir" CLOSED_LOOP_LOCK_WAIT_SECONDS=1 \
      "$ROOT_DIR/script/closed_loop_pipeline.sh" "$@"
  }
  expect_failure() {
    if run "$@" >/dev/null 2>&1; then die "self-test expected failure: $*"; fi
  }
  token() {
    run status "$1" | /usr/bin/ruby -rjson -e 'puts(JSON.parse(STDIN.read).fetch("handoffToken"))'
  }
  reviewed_worktree() {
    run status "$1" | /usr/bin/ruby -rjson -e '
s = JSON.parse(STDIN.read)
puts(s.fetch("artifacts").reverse.find { |a| a["decision"] == "approve" }.fetch("worktreeSha256"))
'
  }
  expect_stage() {
    run status "$1" | /usr/bin/ruby -rjson -e '
state = JSON.parse(STDIN.read)
abort unless state.fetch("currentRole") == ARGV.fetch(0)
abort unless state.fetch("currentStage") == ARGV.fetch(1)
' "$2" "$3"
  }

  run start normal transient >/dev/null
  expect_failure register-role normal Auditor auditor-A GENESIS
  run register-role normal Main main-A GENESIS >/dev/null
  expect_failure submit normal Main main-A "$artifacts/empty.txt"
  run submit normal Main main-A "$artifacts/main.txt" >/dev/null
  local main_token
  main_token="$(token normal)"
  expect_failure register-role normal Auditor main-A "$main_token"
  expect_failure register-role normal Auditor auditor-A wrong-token
  printf 'changed\n' >> "$artifacts/main.txt"
  expect_failure register-role normal Auditor auditor-A "$main_token"
  printf 'main output\n' > "$artifacts/main.txt"
  run register-role normal Auditor auditor-A "$main_token" >/dev/null
  run review normal Auditor auditor-A approve "$artifacts/auditor.txt" >/dev/null
  run register-role normal Main main-A "$(token normal)" >/dev/null
  run status normal | /usr/bin/ruby -rjson -e '
s = JSON.parse(STDIN.read)
abort unless s.fetch("schemaVersion") == 5
abort unless s.fetch("agentPolicy") == "main-plus-single-auditor"
abort unless s.fetch("roleIdentities").keys.sort == %w[Auditor Main]
abort unless s.fetch("artifacts").all? { |a| a.fetch("chainSha256").match?(/\A[0-9a-f]{64}\z/) }
'
  printf 'changed after approval\n' >> "$artifacts/auditor.txt"
  expect_failure close normal Main main-A "$artifacts/close.txt"
  printf 'auditor review\n' > "$artifacts/auditor.txt"
  printf 'post-review worktree change\n' > "$worktree_probe"
  expect_failure close normal Main main-A "$artifacts/close.txt"
  rm "$worktree_probe"
  run close normal Main main-A "$artifacts/close.txt" >/dev/null
  [[ ! -e "$state_dir/runs/normal.json" ]] || die "normal state was not removed"

  run start reject-cycle transient >/dev/null
  run register-role reject-cycle Main main-B GENESIS >/dev/null
  run submit reject-cycle Main main-B "$artifacts/main.txt" >/dev/null
  local rejection
  for rejection in 1 2 3 4 5; do
    run register-role reject-cycle Auditor auditor-B "$(token reject-cycle)" >/dev/null
    run review reject-cycle Auditor auditor-B reject "$artifacts/auditor.txt" >/dev/null
    expect_stage reject-cycle Main main-submit
    expect_failure register-role reject-cycle Main replacement-main "$(token reject-cycle)"
    run register-role reject-cycle Main main-B "$(token reject-cycle)" >/dev/null
    run submit reject-cycle Main main-B "$artifacts/main.txt" >/dev/null
  done
  run register-role reject-cycle Auditor auditor-B "$(token reject-cycle)" >/dev/null
  run review reject-cycle Auditor auditor-B approve "$artifacts/auditor.txt" >/dev/null
  run register-role reject-cycle Main main-B "$(token reject-cycle)" >/dev/null
  run close reject-cycle Main main-B "$artifacts/close.txt" >/dev/null

  run start schema-migration transient >/dev/null
  run register-role schema-migration Main main-M GENESIS >/dev/null
  run submit schema-migration Main main-M "$artifacts/main.txt" >/dev/null
  run register-role schema-migration Auditor auditor-M "$(token schema-migration)" >/dev/null
  run review schema-migration Auditor auditor-M reject "$artifacts/auditor.txt" >/dev/null
  run register-role schema-migration Main main-M "$(token schema-migration)" >/dev/null
  run submit schema-migration Main main-M "$artifacts/main.txt" >/dev/null
  /usr/bin/ruby -rjson -rdigest -e '
path = ARGV.fetch(0)
state = JSON.parse(File.read(path))
state["schemaVersion"] = 4
previous = nil
state.fetch("artifacts").each_with_index do |artifact, index|
  next if index == state.fetch("artifacts").length - 1
  artifact["chainSha256"] = Digest::SHA256.hexdigest([
    previous || "GENESIS", artifact.fetch("order"), artifact.fetch("role"), artifact.fetch("sha256")
  ].join(":"))
  previous = artifact.fetch("chainSha256")
end
state["latestChainSha256"] = state.fetch("artifacts").last.fetch("chainSha256")
File.write(path, JSON.pretty_generate(state) + "\n")
' "$state_dir/runs/schema-migration.json"
  run register-role schema-migration Auditor auditor-M "$(token schema-migration)" >/dev/null
  run status schema-migration | /usr/bin/ruby -rjson -rdigest -e '
s = JSON.parse(STDIN.read)
abort unless s.fetch("schemaVersion") == 5
abort unless s.fetch("migrations").last.values_at("fromSchemaVersion", "toSchemaVersion") == [4, 5]
previous = nil
s.fetch("artifacts").each do |artifact|
  expected = Digest::SHA256.hexdigest([
    previous || "GENESIS",
    artifact.fetch("order"),
    artifact.fetch("role"),
    artifact.fetch("sha256"),
    artifact["decision"] || "",
    artifact["worktreeSha256"] || ""
  ].join(":"))
  abort unless artifact.fetch("chainSha256") == expected
  previous = expected
end
abort unless s.fetch("latestChainSha256") == previous
'

  run start RUN-SELF-TEST durable >/dev/null
  run register-role RUN-SELF-TEST Main main-C GENESIS >/dev/null
  expect_failure submit RUN-SELF-TEST Main main-C "$artifacts/main.txt"
  run submit RUN-SELF-TEST Main main-C "$record" >/dev/null
  run register-role RUN-SELF-TEST Auditor auditor-C "$(token RUN-SELF-TEST)" >/dev/null
  expect_failure review RUN-SELF-TEST Auditor auditor-C approve "$artifacts/auditor.txt"
  run review RUN-SELF-TEST Auditor auditor-C approve "$durable_audit" >/dev/null
  run register-role RUN-SELF-TEST Main main-C "$(token RUN-SELF-TEST)" >/dev/null
  run close RUN-SELF-TEST Main main-C "$artifacts/close.txt" >/dev/null
  [[ -f "$state_dir/completed/RUN-SELF-TEST.json" ]] || die "durable chain was not retained"
  expect_failure start RUN-SELF-TEST durable

  GIT_EXTERNAL_DIFF=/usr/bin/true run start external-diff transient >/dev/null
  GIT_EXTERNAL_DIFF=/usr/bin/true run register-role external-diff Main main-D GENESIS >/dev/null
  GIT_EXTERNAL_DIFF=/usr/bin/true run submit external-diff Main main-D "$artifacts/main.txt" >/dev/null
  GIT_EXTERNAL_DIFF=/usr/bin/true run register-role external-diff Auditor auditor-D "$(token external-diff)" >/dev/null
  GIT_EXTERNAL_DIFF=/usr/bin/true run review external-diff Auditor auditor-D approve "$artifacts/auditor.txt" >/dev/null
  run status external-diff | /usr/bin/ruby -rjson -rdigest -e '
s = JSON.parse(STDIN.read)
approval = s.fetch("artifacts").last
abort unless approval.fetch("worktreeSha256").match?(/\A[0-9a-f]{64}\z/)
expected = Digest::SHA256.hexdigest([
  s.fetch("artifacts")[-2].fetch("chainSha256"),
  approval.fetch("order"),
  approval.fetch("role"),
  approval.fetch("sha256"),
  approval.fetch("decision"),
  approval.fetch("worktreeSha256")
].join(":"))
abort unless approval.fetch("chainSha256") == expected
'
  run start native-diff transient >/dev/null
  run register-role native-diff Main main-E GENESIS >/dev/null
  run submit native-diff Main main-E "$artifacts/main.txt" >/dev/null
  run register-role native-diff Auditor auditor-E "$(token native-diff)" >/dev/null
  run review native-diff Auditor auditor-E approve "$artifacts/auditor.txt" >/dev/null
  [[ "$(reviewed_worktree external-diff)" == "$(reviewed_worktree native-diff)" ]] ||
    die "external diff changed the reviewed worktree digest"

  mkdir -p "$state_dir/locks/locked.lock"
  expect_failure start locked
  rmdir "$state_dir/locks/locked.lock"
  rm -f "$worktree_probe"
  rm -rf "$temp_dir"
  trap - EXIT INT TERM
  echo "Closed-Loop pipeline self-test passed."
}

[[ "$#" -ge 1 ]] || usage
if [[ "$1" == "--self-test" ]]; then
  [[ "$#" -eq 1 ]] || usage
  run_self_test
  exit 0
fi

action="$1"
shift
case "$action" in
  start)
    [[ "$#" -ge 1 && "$#" -le 2 ]] || usage
    validate_run_id "$1"
    with_lock "$1" mutate start "$@"
    ;;
  register-role|submit|close)
    [[ "$#" -eq 4 ]] || usage
    validate_run_id "$1"
    with_lock "$1" mutate "$action" "$@"
    ;;
  review)
    [[ "$#" -eq 5 ]] || usage
    validate_run_id "$1"
    with_lock "$1" mutate review "$@"
    ;;
  status)
    [[ "$#" -eq 1 ]] || usage
    validate_run_id "$1"
    mutate status "$@"
    ;;
  *) usage ;;
esac
