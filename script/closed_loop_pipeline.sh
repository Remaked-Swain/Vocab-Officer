#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_ROOT="${CLOSED_LOOP_STATE_DIR:-$ROOT_DIR/.git/closed-loop-pipeline}"
PROJECT_ROOT="${CLOSED_LOOP_PROJECT_ROOT:-$ROOT_DIR}"
RECORD_VALIDATOR="${CLOSED_LOOP_RECORD_VALIDATOR:-$ROOT_DIR/script/closed_loop_records.sh}"
LOCK_WAIT_SECONDS="${CLOSED_LOOP_LOCK_WAIT_SECONDS:-5}"

usage() {
  cat >&2 <<'EOF'
usage:
  closed_loop_pipeline.sh start <run-id>
  closed_loop_pipeline.sh register-role <run-id> <role> <actor-id> <handoff-token>
  closed_loop_pipeline.sh submit <run-id> <Director|Executor|Recorder> <actor-id> <artifact>
  closed_loop_pipeline.sh review <run-id> Monitor <actor-id> <approve|reject> <artifact>
  closed_loop_pipeline.sh close <run-id> Director <actor-id> <director-close-artifact>
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
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    die "invalid run id: $1"
}

with_lock() {
  local run_id="$1"
  shift
  local lock_root="$STATE_ROOT/locks"
  local lock_dir="$lock_root/$run_id.lock"
  local deadline=$((SECONDS + LOCK_WAIT_SECONDS))

  mkdir -p "$lock_root"
  until mkdir "$lock_dir" 2>/dev/null; do
    (( SECONDS >= deadline )) &&
      die "timed out waiting for concurrent run lock: $run_id"
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
  /usr/bin/ruby -rjson -rdigest -rtempfile -rfileutils -rtime -e '
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
  {
    "role" => role,
    "path" => absolute,
    "sha256" => Digest::SHA256.file(absolute).hexdigest
  }
end

def load_state(path)
  JSON.parse(File.read(path))
rescue Errno::ENOENT
  fail!("run does not exist")
rescue JSON::ParserError => error
  fail!("invalid state: #{error.message}")
end

def expect_current_role!(state, role)
  actual = state.fetch("currentRole")
  fail!("wrong role or future registration: expected #{actual}, received #{role}") unless actual == role
end

def expect_operation!(state, operation)
  actual = state.fetch("currentStage")
  fail!("wrong operation or skipped stage: expected #{actual}, received #{operation}") unless actual == operation
end

def validate_handoff_token!(state, token)
  expected = state.fetch("handoffToken")
  fail!("stale or wrong handoff token") unless token == expected
  return if expected == "GENESIS" && state.fetch("artifacts").empty?

  predecessor = state.fetch("artifacts").last
  fail!("handoff state has no predecessor artifact") unless predecessor
  stored_hash = predecessor.fetch("sha256")
  fail!("handoff state hash mismatch") unless stored_hash == expected && state.fetch("latestArtifactSha256") == expected
  path = predecessor.fetch("path")
  fail!("predecessor artifact is missing at registration") unless File.file?(path)
  current_hash = Digest::SHA256.file(path).hexdigest
  fail!("predecessor artifact changed after submission") unless current_hash == stored_hash && current_hash == token
end

def expect_active_actor!(state, role, actor_id)
  expect_current_role!(state, role)
  fail!("#{role} is not registered for the current stage") unless state.fetch("phase") == "active"
  registration = state.fetch("registrations").last
  fail!("active registration role mismatch") unless registration.fetch("role") == role
  fail!("#{role} identity changed; expected #{registration.fetch("actorId")}") unless registration.fetch("actorId") == actor_id
  registration
end

def save_atomic!(state_dir, state_path, state)
  FileUtils.mkdir_p(state_dir)
  temp = Tempfile.new(["closed-loop-", ".json"], state_dir)
  begin
    temp.write(JSON.pretty_generate(state))
    temp.write("\n")
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
  previous = state["latestArtifactSha256"]
  order = state.fetch("artifacts").length + 1
  chain_input = [
    state["latestChainSha256"] || "GENESIS",
    order,
    artifact.fetch("role"),
    artifact.fetch("sha256")
  ].join(":")
  artifact["order"] = order
  artifact["actorId"] = registration.fetch("actorId")
  artifact["registrationOrder"] = registration.fetch("order")
  artifact["previousSha256"] = previous
  artifact["chainSha256"] = Digest::SHA256.hexdigest(chain_input)
  artifact["recordedAt"] = Time.now.utc.iso8601(6)
  artifact["decision"] = decision if decision
  state.fetch("artifacts") << artifact
  state["latestArtifactSha256"] = artifact.fetch("sha256")
  state["latestChainSha256"] = artifact.fetch("chainSha256")
  state["handoffToken"] = artifact.fetch("sha256")
end

def open_role!(state, role, stage)
  state["currentRole"] = role
  state["currentStage"] = stage
  state["phase"] = "awaiting-registration"
end

def validate_recorder_path!(path, project_root)
  records_dir = File.realpath(File.join(project_root, "Docs", "ClosedLoop", "records"))
  absolute = File.realpath(path)
  fail!("Recorder artifact must be directly under Docs/ClosedLoop/records") unless File.dirname(absolute) == records_dir
  basename = File.basename(absolute)
  match = basename.match(/\A(CL-\d{4,})-[A-Za-z0-9][A-Za-z0-9._-]*\.md\z/)
  fail!("Recorder artifact must match CL-*.md") unless match
  [absolute, match[1]]
rescue Errno::ENOENT
  fail!("Recorder artifact or records directory is missing")
end

def human_index_links_record?(contents, record_id, relative_path)
  contents.each_line.any? do |line|
    next false unless line.start_with?("|")
    cells = line.split("|", -1).map(&:strip)
    next false unless cells[1] == record_id
    line.match?(/\]\(#{Regexp.escape(relative_path)}\)/)
  end
end

def validate_recorder_ledger!(artifact_path, project_root, validator)
  absolute, record_id = validate_recorder_path!(artifact_path, project_root)
  relative = absolute.delete_prefix("#{File.realpath(project_root)}/")
  human_relative = relative.delete_prefix("Docs/ClosedLoop/")
  index_path = File.join(project_root, "Docs", "ClosedLoop", "INDEX.md")
  json_path = File.join(project_root, "Docs", "ClosedLoop", "index.json")
  fail!("INDEX.md is missing") unless File.file?(index_path)
  fail!("index.json is missing") unless File.file?(json_path)
  human = File.read(index_path)
  unless human_index_links_record?(human, record_id, human_relative)
    fail!("INDEX.md does not link #{record_id} to #{human_relative} on its record row")
  end
  data = JSON.parse(File.read(json_path))
  record = data.fetch("records").find { |item| item["id"] == record_id }
  fail!("index.json does not register #{record_id}") unless record
  fail!("index.json path mismatch for #{record_id}") unless record["path"] == relative
  fail!("record validator is not executable: #{validator}") unless File.file?(validator) && File.executable?(validator)
  valid = Dir.chdir(project_root) { system(validator, "validate", out: File::NULL, err: File::NULL) }
  fail!("closed-loop record validation failed") unless valid
rescue JSON::ParserError, KeyError => error
  fail!("invalid recorder ledger: #{error.message}")
end

case action
when "start"
  fail!("run already exists: #{run_id}") if File.exist?(state_path)
  state = {
    "schemaVersion" => 2,
    "runId" => run_id,
    "currentRole" => "Director",
    "currentStage" => "director-submit",
    "phase" => "awaiting-registration",
    "handoffToken" => "GENESIS",
    "rejectionCount" => 0,
    "roleIdentities" => {},
    "registrations" => [],
    "artifacts" => [],
    "latestArtifactSha256" => nil,
    "latestChainSha256" => nil
  }
  save_atomic!(state_dir, state_path, state)
  puts("started #{run_id}; register Director with handoff token GENESIS")
when "register-role"
  role, actor_id, token = args
  fail!("invalid role: #{role}") unless %w[Director Executor Monitor Recorder].include?(role)
  state = load_state(state_path)
  expect_current_role!(state, role)
  fail!("#{role} is already registered for the current stage") unless state.fetch("phase") == "awaiting-registration"
  actor_id = actor!(actor_id, role)
  validate_handoff_token!(state, token)
  identities = state.fetch("roleIdentities")
  if identities.key?(role) && identities.fetch(role) != actor_id
    fail!("#{role} identity changed; expected #{identities.fetch(role)}")
  end
  identities[role] ||= actor_id
  registration = {
    "order" => state.fetch("registrations").length + 1,
    "role" => role,
    "actorId" => actor_id,
    "registeredAt" => Time.now.utc.iso8601(6),
    "handoffToken" => token,
    "kind" => identities.fetch(role) == actor_id && state.fetch("registrations").any? { |item| item["role"] == role } ? "reactivated" : "registered"
  }
  state.fetch("registrations") << registration
  state["phase"] = "active"
  save_atomic!(state_dir, state_path, state)
  puts("registered #{role} as order #{registration.fetch("order")}")
when "submit"
  role, actor_id, artifact_path = args
  fail!("submit role must be Director, Executor or Recorder") unless %w[Director Executor Recorder].include?(role)
  state = load_state(state_path)
  registration = expect_active_actor!(state, role, actor!(actor_id, role))
  expected_stage = {
    "Director" => "director-submit",
    "Executor" => "executor-submit",
    "Recorder" => "recorder-submit"
  }.fetch(role)
  expect_operation!(state, expected_stage)
  if role == "Recorder"
    validate_recorder_path!(artifact_path, project_root)
  end
  artifact = artifact!(artifact_path, role)
  append_artifact!(state, artifact, registration)
  next_role, next_stage = {
    "Director" => ["Executor", "executor-submit"],
    "Executor" => ["Monitor", "monitor-review"],
    "Recorder" => ["Director", "director-close"]
  }.fetch(role)
  open_role!(state, next_role, next_stage)
  save_atomic!(state_dir, state_path, state)
  puts("accepted #{role} artifact; register #{next_role} with handoff token #{state.fetch("handoffToken")}")
when "review"
  role, actor_id, decision, artifact_path = args
  fail!("review role must be Monitor") unless role == "Monitor"
  fail!("review decision must be approve or reject") unless %w[approve reject].include?(decision)
  state = load_state(state_path)
  registration = expect_active_actor!(state, role, actor!(actor_id, role))
  expect_operation!(state, "monitor-review")
  if decision == "reject" && state.fetch("rejectionCount") >= 3
    fail!("rejection limit reached (3)")
  end
  artifact = artifact!(artifact_path, role)
  append_artifact!(state, artifact, registration, decision)
  if decision == "reject"
    state["rejectionCount"] += 1
    open_role!(state, "Executor", "executor-submit")
  else
    open_role!(state, "Recorder", "recorder-submit")
  end
  save_atomic!(state_dir, state_path, state)
  puts("#{decision} recorded; register #{state.fetch("currentRole")} with handoff token #{state.fetch("handoffToken")}")
when "close"
  role, actor_id, artifact_path = args
  fail!("close role must be Director") unless role == "Director"
  state = load_state(state_path)
  registration = expect_active_actor!(state, role, actor!(actor_id, role))
  expect_operation!(state, "director-close")
  recorder = state.fetch("artifacts").reverse.find { |item| item["role"] == "Recorder" }
  fail!("Recorder artifact is required before close") unless recorder
  fail!("Recorder artifact is missing at close") unless File.file?(recorder.fetch("path"))
  current_recorder_hash = Digest::SHA256.file(recorder.fetch("path")).hexdigest
  fail!("Recorder artifact changed after submission") unless current_recorder_hash == recorder.fetch("sha256")
  validate_recorder_ledger!(recorder.fetch("path"), project_root, validator)
  artifact = artifact!(artifact_path, "Director")
  append_artifact!(state, artifact, registration)
  File.unlink(state_path)
  puts("closed #{run_id}; recorder ledger validated and temporary state removed")
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
  local fixture_root="$temp_dir/project"
  local artifacts="$temp_dir/artifacts"
  local records="$fixture_root/Docs/ClosedLoop/records"
  local recorder="$records/CL-9999-fixture.md"
  local validator="$fixture_root/validate-records.sh"
  mkdir -p "$artifacts" "$records"
  printf 'director brief\n' > "$artifacts/director.txt"
  printf 'executor output\n' > "$artifacts/executor.txt"
  printf 'monitor review\n' > "$artifacts/monitor.txt"
  printf 'director close\n' > "$artifacts/close.txt"
  printf '# CL-9999\n\n| Status | active |\n' > "$recorder"
  printf '| CL-9999 | active | [Fixture](records/CL-9999-fixture.md) |\n' \
    > "$fixture_root/Docs/ClosedLoop/INDEX.md"
  printf '{"records":[{"id":"CL-9999","path":"Docs/ClosedLoop/records/CL-9999-fixture.md"}]}\n' \
    > "$fixture_root/Docs/ClosedLoop/index.json"
  printf '#!/usr/bin/env bash\n[[ "$1" == validate && ! -e validator.fail ]]\n' > "$validator"
  chmod +x "$validator"
  : > "$artifacts/empty.txt"

  run() {
    CLOSED_LOOP_STATE_DIR="$state_dir" \
    CLOSED_LOOP_PROJECT_ROOT="$fixture_root" \
    CLOSED_LOOP_RECORD_VALIDATOR="$validator" \
    CLOSED_LOOP_LOCK_WAIT_SECONDS=1 \
      "$ROOT_DIR/script/closed_loop_pipeline.sh" "$@"
  }
  expect_failure() {
    if run "$@" >/dev/null 2>&1; then
      die "self-test expected failure: $*"
    fi
  }
  token() {
    run status "$1" | /usr/bin/ruby -rjson -e \
      'puts(JSON.parse(STDIN.read).fetch("handoffToken"))'
  }
  expect_role_phase() {
    run status "$1" | /usr/bin/ruby -rjson -e '
state = JSON.parse(STDIN.read)
abort unless state.fetch("currentRole") == ARGV.fetch(0)
abort unless state.fetch("phase") == ARGV.fetch(1)
' "$2" "$3"
  }

  run start normal >/dev/null
  expect_failure register-role normal Executor executor-A GENESIS
  run register-role normal Director director-A GENESIS >/dev/null
  expect_failure register-role normal Director director-A GENESIS
  expect_failure submit normal Director director-A "$artifacts/empty.txt"
  run submit normal Director director-A "$artifacts/director.txt" >/dev/null
  local director_token
  director_token="$(token normal)"
  expect_failure register-role normal Executor executor-A GENESIS
  expect_failure register-role normal Executor executor-A wrong-token
  printf '\nchanged before successor registration\n' >> "$artifacts/director.txt"
  expect_failure register-role normal Executor executor-A "$director_token"
  printf 'director brief\n' > "$artifacts/director.txt"
  run register-role normal Executor executor-A "$director_token" >/dev/null
  run submit normal Executor executor-A "$artifacts/executor.txt" >/dev/null
  run register-role normal Monitor monitor-A "$(token normal)" >/dev/null
  run review normal Monitor monitor-A approve "$artifacts/monitor.txt" >/dev/null
  run register-role normal Recorder recorder-A "$(token normal)" >/dev/null
  expect_failure submit normal Recorder recorder-A "$artifacts/executor.txt"
  run submit normal Recorder recorder-A "$recorder" >/dev/null
  run status normal | /usr/bin/ruby -rjson -e '
state = JSON.parse(STDIN.read)
abort unless state.fetch("registrations").map { |item| item.fetch("order") } == [1, 2, 3, 4]
abort unless state.fetch("registrations").all? { |item| item.fetch("registeredAt").include?("T") }
artifacts = state.fetch("artifacts")
abort unless artifacts.each_cons(2).all? { |left, right| right.fetch("previousSha256") == left.fetch("sha256") }
  abort unless artifacts.all? { |item| item.fetch("chainSha256").match?(/\A[0-9a-f]{64}\z/) }
'
  run register-role normal Director director-A "$(token normal)" >/dev/null
  expect_failure submit normal Director director-A "$artifacts/director.txt"
  printf '\nchanged after submit\n' >> "$recorder"
  expect_failure close normal Director director-A "$artifacts/close.txt"
  printf '# CL-9999\n\n| Status | active |\n' > "$recorder"
  printf '{"records":[]}\n' > "$fixture_root/Docs/ClosedLoop/index.json"
  expect_failure close normal Director director-A "$artifacts/close.txt"
  printf '{"records":[{"id":"CL-9999","path":"Docs/ClosedLoop/records/CL-9999-fixture.md"}]}\n' \
    > "$fixture_root/Docs/ClosedLoop/index.json"
  printf '| CL-9999 | active | [Fixture](records/CL-9999-wrong.md) |\n' \
    > "$fixture_root/Docs/ClosedLoop/INDEX.md"
  expect_failure close normal Director director-A "$artifacts/close.txt"
  printf '| CL-9999 | active | [Fixture](records/CL-9999-fixture.md) |\n' \
    > "$fixture_root/Docs/ClosedLoop/INDEX.md"
  touch "$fixture_root/validator.fail"
  expect_failure close normal Director director-A "$artifacts/close.txt"
  rm "$fixture_root/validator.fail"
  run close normal Director director-A "$artifacts/close.txt" >/dev/null
  [[ ! -e "$state_dir/runs/normal.json" ]] || die "normal run state was not removed"

  run start reject-cycle >/dev/null
  run register-role reject-cycle Director director-B GENESIS >/dev/null
  run submit reject-cycle Director director-B "$artifacts/director.txt" >/dev/null
  run register-role reject-cycle Executor executor-B "$(token reject-cycle)" >/dev/null
  run submit reject-cycle Executor executor-B "$artifacts/executor.txt" >/dev/null
  local rejection
  for rejection in 1 2 3; do
    run register-role reject-cycle Monitor monitor-B "$(token reject-cycle)" >/dev/null
    run review reject-cycle Monitor monitor-B reject "$artifacts/monitor.txt" >/dev/null
    expect_role_phase reject-cycle Executor awaiting-registration
    expect_failure register-role reject-cycle Executor replacement-executor "$(token reject-cycle)"
    run register-role reject-cycle Executor executor-B "$(token reject-cycle)" >/dev/null
    run submit reject-cycle Executor executor-B "$artifacts/executor.txt" >/dev/null
  done
  run register-role reject-cycle Monitor monitor-B "$(token reject-cycle)" >/dev/null
  expect_failure review reject-cycle Monitor monitor-B reject "$artifacts/monitor.txt"
  run review reject-cycle Monitor monitor-B approve "$artifacts/monitor.txt" >/dev/null
  run register-role reject-cycle Recorder recorder-B "$(token reject-cycle)" >/dev/null
  run submit reject-cycle Recorder recorder-B "$recorder" >/dev/null
  run register-role reject-cycle Director director-B "$(token reject-cycle)" >/dev/null
  run close reject-cycle Director director-B "$artifacts/close.txt" >/dev/null
  [[ ! -e "$state_dir/runs/reject-cycle.json" ]] || die "reject-cycle state was not removed"

  mkdir -p "$state_dir/locks/locked.lock"
  expect_failure start locked
  rmdir "$state_dir/locks/locked.lock"

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
    [[ "$#" -eq 1 ]] || usage
    validate_run_id "$1"
    with_lock "$1" mutate start "$@"
    ;;
  register-role)
    [[ "$#" -eq 4 ]] || usage
    validate_run_id "$1"
    with_lock "$1" mutate register-role "$@"
    ;;
  submit)
    [[ "$#" -eq 4 ]] || usage
    validate_run_id "$1"
    with_lock "$1" mutate submit "$@"
    ;;
  review)
    [[ "$#" -eq 5 ]] || usage
    validate_run_id "$1"
    with_lock "$1" mutate review "$@"
    ;;
  close)
    [[ "$#" -eq 4 ]] || usage
    validate_run_id "$1"
    with_lock "$1" mutate close "$@"
    ;;
  status)
    [[ "$#" -eq 1 ]] || usage
    validate_run_id "$1"
    mutate status "$@"
    ;;
  *)
    usage
    ;;
esac
