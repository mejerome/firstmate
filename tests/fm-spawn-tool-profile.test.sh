#!/usr/bin/env bash
# tests/fm-spawn-tool-profile.test.sh - regression coverage for
# bin/fm-spawn.sh --tool-profile.
#
# Coverage:
#   - --tool-profile monitor on the Pi family launches with the harness's own
#     --exclude-tools denylist naming the five MCP server prefixes, keeps the
#     -e extension flags that carry the watcher and turn-end guard, and records
#     tool_profile=monitor in the task record
#   - no flag (the default) and --tool-profile incident both launch with the
#     full tool set: no --exclude-tools, and no --no-mcp or --no-extensions
#     either (both of those would change the default behavior), while still
#     recording tool_profile=incident
#   - an unknown profile is refused by name before any worktree or record, so
#     it can never fall back silently to the full set
#   - a profile the resolved harness cannot express is refused naming that
#     harness, instead of launching with an unexpressed profile
#   - --relaunch refuses the flag, because a replacement worker keeps the tool
#     surface its task was dispatched with
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-tool-profile)

# make_tool_profile_fakebin <dir>: a fake tmux that logs every send-keys payload
# (so the exact launch literal is observable), a fake treehouse, and a fake pi
# whose --help advertises neither --tui-mode nor --approve, so the launch shape
# under test is the plain one.
make_tool_profile_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *)
            case "$a" in
              ". '"*"'") staged=${a#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || a=$(cat "$staged") ;;
            esac
            printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'usage: pi [options] [messages...]'
  printf '%s\n' '  --model <pattern>  Model pattern'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/pi"
  printf '%s\n' "$fakebin"
}

# make_tool_profile_case <name> <harness>: a home, a project with a real
# worktree, and a brief, wired to the fixture fakebin. Echoes
# home|proj|wt|fakebin|launchlog|id.
make_tool_profile_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_tool_profile_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the tool profile for $id.

## Firstmate spec
Record the profile this worker runs with.
EOF
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

read_tool_profile_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

run_tool_profile_spawn() {
  : > "$LAUNCH_LOG"
  mkdir -p "$HOME_DIR/user-home"
  env -u FM_TRACE_CONTEXT -u PI_CODING_AGENT -u FM_PI_HARNESS \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$CASE_ID" "$PROJ_DIR" --mode no-mistakes --yolo off "$@" 2>&1
}

# The five MCP server prefixes this profile excludes, in the exact form the
# launch must carry them.
TOOL_PROFILE_PREFIXES='github-*,context7-*,firecrawl-*,searxng-*,ra-h-os-*'

launch_line() {
  grep -F 'FM_PI_HARNESS' "$LAUNCH_LOG" | tail -1
}

case_monitor_records_exclusion_flags() {
  local rec out status launch meta
  rec=$(make_tool_profile_case tp-monitor pi)
  read_tool_profile_case "$rec"

  out=$(run_tool_profile_spawn --harness pi --tool-profile monitor)
  status=$?
  expect_code 0 "$status" "a monitor spawn on pi should succeed"
  assert_contains "$out" "spawned $CASE_ID" "a monitor spawn should report success"
  assert_contains "$out" "tool_profile=monitor" "the spawned line should state the tool profile"

  launch=$(launch_line)
  assert_contains "$launch" '--exclude-tools' "a monitor launch must carry --exclude-tools"
  assert_contains "$launch" "$TOOL_PROFILE_PREFIXES" \
    "a monitor launch must exclude the five MCP server prefixes"
  # The exclusion must not be achieved by dropping extensions: the Pi turn-end
  # extension is what carries the watcher and turn-end guard.
  assert_contains "$launch" '-e ' "a monitor launch must keep the -e extension flags"
  assert_not_contains "$launch" '--no-extensions' "a monitor launch must never use --no-extensions"
  assert_not_contains "$launch" '--no-mcp' "a monitor launch must never use --no-mcp"

  meta="$HOME_DIR/state/$CASE_ID.meta"
  assert_contains "$(cat "$meta")" 'tool_profile=monitor' \
    "the task record must state the monitor profile"
  pass "monitor: the launch carries the MCP exclusion flags and the record says monitor"
}

case_default_profile_is_unchanged() {
  local rec out status launch meta
  rec=$(make_tool_profile_case tp-default pi)
  read_tool_profile_case "$rec"

  out=$(run_tool_profile_spawn --harness pi)
  status=$?
  expect_code 0 "$status" "a default-profile spawn should succeed"
  assert_contains "$out" "tool_profile=incident" \
    "the spawned line should state the default profile explicitly"

  launch=$(launch_line)
  assert_not_contains "$launch" '--exclude-tools' \
    "the default profile must not exclude any tool"
  assert_not_contains "$launch" '--no-mcp' "the default profile must keep MCP"
  assert_not_contains "$launch" '--no-extensions' "the default profile must keep extensions"

  meta="$HOME_DIR/state/$CASE_ID.meta"
  assert_contains "$(cat "$meta")" 'tool_profile=incident' \
    "the task record must state the default profile"
  pass "default: no exclusion flag is emitted and the record says incident"
}

case_explicit_incident_profile_keeps_every_tool() {
  local rec out status launch
  rec=$(make_tool_profile_case tp-incident pi)
  read_tool_profile_case "$rec"

  out=$(run_tool_profile_spawn --harness pi --tool-profile incident)
  status=$?
  expect_code 0 "$status" "an explicit incident spawn should succeed"
  assert_contains "$out" "tool_profile=incident" "the spawned line should state incident"

  launch=$(launch_line)
  assert_not_contains "$launch" '--exclude-tools' \
    "the incident profile must keep the full tool set available"
  pass "incident: the full tool set stays available"
}

case_unknown_profile_is_refused_by_name() {
  local rec out status
  rec=$(make_tool_profile_case tp-unknown pi)
  read_tool_profile_case "$rec"

  out=$(run_tool_profile_spawn --harness pi --tool-profile telemetry)
  status=$?
  expect_code 1 "$status" "an unknown profile must be refused"
  assert_contains "$out" "telemetry" "the refusal must name the unknown profile"
  ! [ -e "$HOME_DIR/state/$CASE_ID.meta" ] \
    || fail "a refused profile must not leave a task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused profile must not launch anything"
  pass "unknown profile: refused by name before any record or launch"
}

case_inexpressible_harness_is_refused_by_name() {
  local rec out status
  rec=$(make_tool_profile_case tp-claude claude)
  read_tool_profile_case "$rec"

  out=$(run_tool_profile_spawn --harness claude --tool-profile monitor)
  status=$?
  expect_code 1 "$status" "a profile the harness cannot express must be refused"
  assert_contains "$out" 'monitor' "the refusal must name the requested profile"
  assert_contains "$out" 'claude' "the refusal must name the harness"
  ! [ -e "$HOME_DIR/state/$CASE_ID.meta" ] \
    || fail "a refused harness profile must not leave a task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused harness profile must not launch anything"
  pass "inexpressible harness: refused by name instead of launching without the profile"
}

case_relaunch_reuses_the_recorded_profile() {
  local rec out status
  rec=$(make_tool_profile_case tp-relaunch pi)
  read_tool_profile_case "$rec"
  : > "$LAUNCH_LOG"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$CASE_ID" --relaunch --tool-profile monitor 2>&1)
  status=$?
  expect_code 1 "$status" "a relaunch must refuse a tool-profile override"
  assert_contains "$out" 'recorded tool profile' \
    "the refusal must say the replacement reuses the recorded profile"
  [ ! -e "$HOME_DIR/state/$CASE_ID.meta" ] || fail "a refused relaunch must not write a record"
  pass "relaunch: the recorded tool profile is reused, never overridden"
}

case_monitor_records_exclusion_flags
case_default_profile_is_unchanged
case_explicit_incident_profile_keeps_every_tool
case_unknown_profile_is_refused_by_name
case_inexpressible_harness_is_refused_by_name
case_relaunch_reuses_the_recorded_profile

echo "# all fm-spawn-tool-profile tests passed"
