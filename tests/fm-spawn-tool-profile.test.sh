#!/usr/bin/env bash
# tests/fm-spawn-tool-profile.test.sh - regression coverage for
# bin/fm-spawn.sh --tool-profile.
#
# Coverage:
#   - --tool-profile monitor on the Pi family launches with the whole lean
#     surface: the harness's own --exclude-tools denylist naming the five MCP
#     server prefixes, -nc so AGENTS.md never enters the prompt, a
#     --append-system-prompt naming the tracked compact lane contract, and -ns
#     with one explicit --skill per skill this lane needs; it keeps the -e
#     extension flags that carry the watcher and turn-end guard, and records
#     tool_profile=monitor in the task record
#   - no flag (the default) and --tool-profile incident both launch with the
#     full surface: no --exclude-tools, no -nc, no -ns, no --skill, no
#     --append-system-prompt, and no --no-mcp or --no-extensions either (each of
#     those would change the default behavior), while still recording
#     tool_profile=incident
#   - default and incident launch lines from the same fixture are byte-identical,
#     because incident IS the default and neither carries any monitor flag
#   - the compact lane contract exists and stays inside its size ceiling, because
#     it is the file that replaces the supervisor contract monitor stops loading
#   - the compact lane contract names the tools and surfaces the monitoring lane
#     demonstrably uses: bash, read, the watcher, the turn-end guard, and the
#     skill path pattern
#   - a monitor spawn whose code root has no compact lane contract is refused by
#     path instead of launching with neither contract
#   - a monitor no-mistakes spend refuses when the pipeline skill cannot be
#     resolved, because a narrowed index without it could not drive validation
#   - --secondmate accepts monitor rather than silently downgrading it; the
#     documented decision is asserted here so a later blanket refusal cannot
#     change it unnoticed
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
  # The machine-wide no-mistakes skill exists on every real fleet host, so the
  # fixture seeds it: without it a monitor no-mistakes spawn is refused by design
  # (case_missing_pipeline_skill_is_refused).
  mkdir -p "$home/user-home/.agents/skills/no-mistakes"
  cat > "$home/user-home/.agents/skills/no-mistakes/SKILL.md" <<'SKILL'
---
name: no-mistakes
description: Fixture stand-in for the pipeline skill.
---

# no-mistakes
SKILL
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
  local delivery=(--mode no-mistakes --yolo off) arg
  : > "$LAUNCH_LOG"
  mkdir -p "$HOME_DIR/user-home"
  # A secondmate spawn takes its own fixed posture and refuses --mode, so the
  # ship delivery flags are dropped for that shape.
  for arg in "$@"; do
    [ "$arg" = --secondmate ] && delivery=()
  done
  env -u FM_TRACE_CONTEXT -u PI_CODING_AGENT -u FM_PI_HARNESS \
    FM_ROOT_OVERRIDE="${CASE_FM_ROOT_OVERRIDE:-}" FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$CASE_ID" "$PROJ_DIR" ${delivery[@]+"${delivery[@]}"} "$@" 2>&1
}

# The five MCP server prefixes this profile excludes, in the exact form the
# launch must carry them, and the tracked compact contract the profile appends in
# place of the supervisor contract.
TOOL_PROFILE_PREFIXES='github-*,context7-*,firecrawl-*,searxng-*,ra-h-os-*'
CONTRACT_REL='docs/monitor-lane-contract.md'

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
  # The context cut: AGENTS.md discovery off, the compact contract in its place.
  assert_contains "$launch" '-nc' "a monitor launch must stop loading context files"
  assert_contains "$launch" '--append-system-prompt' \
    "a monitor launch must append the compact lane contract"
  assert_contains "$launch" "$ROOT/$CONTRACT_REL" \
    "a monitor launch must name the tracked compact lane contract by absolute path"
  # The skills cut: discovery off, one explicit path per needed skill.
  assert_contains "$launch" '-ns' "a monitor launch must stop loading the skills index"
  assert_contains "$launch" '--skill' "a monitor launch must name its skills explicitly"
  assert_contains "$launch" "$HOME_DIR/user-home/.agents/skills/no-mistakes" \
    "a monitor launch must keep the pipeline skill it can resolve"
  assert_contains "$launch" "$ROOT/.agents/skills/stow" \
    "a monitor launch must keep the stow skill from its own code root"
  # The exclusion must not be achieved by dropping extensions: the Pi turn-end
  # extension is what carries the watcher and turn-end guard.
  assert_contains "$launch" '-e ' "a monitor launch must keep the -e extension flags"
  assert_not_contains "$launch" '--no-extensions' "a monitor launch must never use --no-extensions"
  assert_not_contains "$launch" '--no-mcp' "a monitor launch must never use --no-mcp"

  meta="$HOME_DIR/state/$CASE_ID.meta"
  assert_contains "$(cat "$meta")" 'tool_profile=monitor' \
    "the task record must state the monitor profile"
  pass "monitor: the launch carries the whole lean surface and the record says monitor"
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
  assert_not_contains "$launch" '-nc' "the default profile must keep loading context files"
  assert_not_contains "$launch" '--no-context-files' \
    "the default profile must keep loading context files"
  assert_not_contains "$launch" '-ns' "the default profile must keep the skills index"
  assert_not_contains "$launch" '--no-skills' "the default profile must keep the skills index"
  assert_not_contains "$launch" '--skill' \
    "the default profile must not narrow the skills index"
  assert_not_contains "$launch" '--append-system-prompt' \
    "the default profile must not replace the supervisor contract"

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
  assert_not_contains "$launch" '-nc' \
    "the incident profile must keep loading context files"
  assert_not_contains "$launch" '--no-context-files' \
    "the incident profile must keep loading context files"
  assert_not_contains "$launch" '--append-system-prompt' \
    "the incident profile must keep the supervisor contract"
  assert_not_contains "$launch" '-ns' "the incident profile must keep the skills index"
  assert_not_contains "$launch" '--no-skills' \
    "the incident profile must keep the skills index"
  assert_not_contains "$launch" '--skill' \
    "the incident profile must not narrow the skills index"
  pass "incident: the full tool set, contract, and skills index stay available"
}

case_compact_contract_fits_its_ceiling() {
  local contract bytes tokens
  contract="$ROOT/$CONTRACT_REL"
  [ -f "$contract" ] || fail "the compact lane contract is missing at $contract"
  bytes=$(wc -c < "$contract")
  [ "$bytes" -gt 0 ] || fail "the compact lane contract is empty"
  # Measured ratio on the monitoring lane's own model: about 4 bytes per prompt
  # token, so the 2,000-token hard ceiling is 8,000 bytes and the 1,200-token
  # target is 4,800 bytes. The file measured 4,543 bytes, about 1,136 tokens.
  tokens=$((bytes / 4))
  [ "$bytes" -le 8000 ] \
    || fail "the compact lane contract is $bytes bytes (about $tokens tokens), past its 2,000-token ceiling"
  pass "contract: $bytes bytes, about $tokens tokens, inside the 2,000-token ceiling"
}

case_compact_contract_covers_retained_surfaces() {
  local contract
  contract="$ROOT/$CONTRACT_REL"
  # The compact lane contract is an owned agent-runtime text contract. Read it
  # and assert the surfaces the monitoring lane demonstrably uses are named.
  assert_contains "$(cat "$contract")" 'bash' \
    "the compact contract must name bash as a retained surface"
  assert_contains "$(cat "$contract")" 'read' \
    "the compact contract must name read as a retained surface"
  assert_contains "$(cat "$contract")" 'the watcher' \
    "the compact contract must name the watcher as a retained surface"
  assert_contains "$(cat "$contract")" 'turn-end guard' \
    "the compact contract must name the turn-end guard as a retained surface"
  assert_contains "$(cat "$contract")" '.agents/skills/<name>/SKILL.md' \
    "the compact contract must name the skill path pattern for loading skills by path"
  pass "contract: the compact contract names the retained tools and the skill path pattern"
}

case_missing_contract_is_refused_by_path() {
  local rec out status bare_root
  rec=$(make_tool_profile_case tp-nocontract pi)
  read_tool_profile_case "$rec"
  # A code root that resolves every other script and skill but carries no docs/,
  # so the only thing missing is the compact contract this profile appends.
  bare_root="$(dirname "$PROJ_DIR")/bare-root"
  mkdir -p "$bare_root"
  ln -s "$ROOT/bin" "$bare_root/bin"
  ln -s "$ROOT/.agents" "$bare_root/.agents"
  CASE_FM_ROOT_OVERRIDE="$bare_root"
  out=$(run_tool_profile_spawn --harness pi --tool-profile monitor)
  status=$?
  CASE_FM_ROOT_OVERRIDE=
  expect_code 1 "$status" "a monitor spawn without the compact contract must be refused"
  assert_contains "$out" "$CONTRACT_REL" \
    "the refusal must name the missing compact contract by path"
  ! [ -e "$HOME_DIR/state/$CASE_ID.meta" ] \
    || fail "a refused monitor spawn must not leave a task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused monitor spawn must not launch anything"
  pass "contract: a missing compact contract is refused by path before any launch"
}

case_missing_pipeline_skill_is_refused() {
  local rec out status skill
  rec=$(make_tool_profile_case tp-nopipeline pi)
  read_tool_profile_case "$rec"
  skill="$HOME_DIR/user-home/.agents/skills/no-mistakes"
  rm -rf "$skill"
  out=$(run_tool_profile_spawn --harness pi --tool-profile monitor)
  status=$?
  expect_code 1 "$status" "a monitor no-mistakes spawn without the pipeline skill must be refused"
  assert_contains "$out" "no-mistakes skill" "the refusal must name the missing pipeline skill"
  assert_contains "$out" "incident profile" \
    "the refusal must name the profile that still works"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused monitor spawn must not launch anything"
  pass "skills: a missing pipeline skill refuses a no-mistakes monitor spawn"
}

case_secondmate_accepts_the_monitor_profile() {
  local rec out status
  rec=$(make_tool_profile_case tp-secondmate pi)
  read_tool_profile_case "$rec"
  # The home is not a seeded secondmate home, so this spawn stops at that check.
  # Reaching it proves the monitor profile was not refused for a secondmate; the
  # documented decision is that a mate keeps the lean contract.
  out=$(run_tool_profile_spawn --harness pi --secondmate --tool-profile monitor)
  status=$?
  expect_code 1 "$status" "an unseeded secondmate home must be refused"
  assert_contains "$out" 'not a seeded secondmate home' \
    "the secondmate spawn must stop at the home check, not at the profile"
  assert_not_contains "$out" 'tool-profile monitor is not' \
    "a secondmate spawn must accept the monitor profile rather than downgrade it"
  pass "secondmate: the monitor profile is accepted for a mate launch"
}

case_default_and_incident_launch_lines_match() {
  local rec out1 out2 rc1 rc2 launch1 launch2 meta1
  # One fixture, two spawns: one without the flag (default), one explicit.
  # Both must produce byte-identical launch lines because incident is the
  # default profile; neither may carry any monitor-specific flag.
  rec=$(make_tool_profile_case tp-matching pi)
  read_tool_profile_case "$rec"

  # First spawn: default (no --tool-profile)
  : > "$LAUNCH_LOG"
  out1=$(run_tool_profile_spawn --harness pi)
  rc1=$?
  launch1=$(launch_line)
  meta1="$HOME_DIR/state/$CASE_ID.meta"

  expect_code 0 "$rc1" "the first (default) spawn should succeed"
  assert_contains "$out1" "tool_profile=incident" \
    "the default spawned line must state the incident profile"
  assert_contains "$(cat "$meta1")" 'tool_profile=incident' \
    "the default task record must state the incident profile"

  # Second spawn: explicit --tool-profile incident on the SAME fixture
  : > "$LAUNCH_LOG"
  out2=$(run_tool_profile_spawn --harness pi --tool-profile incident)
  rc2=$?
  launch2=$(launch_line)

  expect_code 0 "$rc2" "the explicit incident spawn should succeed"
  assert_contains "$out2" "tool_profile=incident" \
    "the incident spawned line must state the incident profile"

  # The two launch lines must be byte-identical: incident IS the default.
  assert_equals "$launch1" "$launch2" \
    "default and incident launch lines must be byte-identical"

  # Neither launch carries any monitor-specific flag.
  assert_not_contains "$launch1" '--exclude-tools' \
    "the default launch must not exclude any tool"
  assert_not_contains "$launch2" '--exclude-tools' \
    "the incident launch must not exclude any tool"
  assert_not_contains "$launch1" '-nc' \
    "the default launch must not stop loading context files"
  assert_not_contains "$launch2" '-nc' \
    "the incident launch must not stop loading context files"
  assert_not_contains "$launch1" '--append-system-prompt' \
    "the default launch must not replace the supervisor contract"
  assert_not_contains "$launch2" '--append-system-prompt' \
    "the incident launch must not replace the supervisor contract"
  assert_not_contains "$launch1" '-ns' \
    "the default launch must not stop loading the skills index"
  assert_not_contains "$launch2" '-ns' \
    "the incident launch must not stop loading the skills index"
  assert_not_contains "$launch1" '--skill' \
    "the default launch must not name any explicit skill"
  assert_not_contains "$launch2" '--skill' \
    "the incident launch must not name any explicit skill"
  pass "default and incident: launch lines are byte-identical and carry none of the monitor flags"
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
case_compact_contract_fits_its_ceiling
case_compact_contract_covers_retained_surfaces
case_missing_contract_is_refused_by_path
case_missing_pipeline_skill_is_refused
case_secondmate_accepts_the_monitor_profile
case_default_profile_is_unchanged
case_explicit_incident_profile_keeps_every_tool
case_default_and_incident_launch_lines_match
case_unknown_profile_is_refused_by_name
case_inexpressible_harness_is_refused_by_name
case_relaunch_reuses_the_recorded_profile

echo "# all fm-spawn-tool-profile tests passed"
