#!/usr/bin/env bash
# tests/fm-session-start-secondmate-checkpoint.test.sh - regression coverage for
# the bounded secondmate checkpoint in bin/fm-session-start.sh.
#
# A secondmate home is a firstmate instance, but its session-start digest is a
# WORKER's own context: everything printed there is carried into every request
# that session makes. So the bulky sections - the whole task-record listing, the
# backlog listing, and the context files - must not be injected into a mate's
# own startup. This test drives the real script twice against the same home,
# once with the secondmate marker and once without, and asserts:
#   - the secondmate digest keeps the lock line and the wake queue state,
#   - it prints the bounded checkpoint with the on-demand read commands,
#   - it does NOT print the task record body, the backlog body, or the context
#     file bodies,
#   - it still states each context file's presence (ABSENT semantics survive),
#   - the same home WITHOUT the marker prints the full digest as before, and
#     the documented full-digest escape prints it in a secondmate home too.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SESSION_START="$ROOT/bin/fm-session-start.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-session-start-secondmate-checkpoint)
TASK_ID=matecheck-z1
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

# make_fakebin <fakebin>: the tools the digest's composition and bootstrap
# detection touch, all quiet, plus a ps that reports a live harness so the
# session takes the fleet lock instead of falling back to read-only.
make_fakebin() {
  local fakebin=$1
  fm_fake_exit0 "$fakebin" tmux treehouse node
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # The lock owner is the harness process in this script's ancestry, so the ps
  # stub reports one specific pid (FM_FAKE_HARNESS_PID) as that harness and
  # delegates the parent query to the real ps, exactly like the session-start
  # suite's fixture. Without it the session falls back to read-only.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ -z "${FM_FAKE_HARNESS_PID:-}" ] || [ "$pid" = "$FM_FAKE_HARNESS_PID" ]; then
      printf '/usr/local/bin/claude\n'
    else
      printf '/bin/bash\n'
    fi
    exit 0
    ;;
  *"args="*)
    if [ -z "${FM_FAKE_HARNESS_PID:-}" ] || [ "$pid" = "$FM_FAKE_HARNESS_PID" ]; then
      printf 'claude\n'
    else
      printf 'bash\n'
    fi
    exit 0
    ;;
  *"ppid="*)
    [ -n "${FM_FAKE_HARNESS_PID:-}" ] || exit 1
    /bin/ps -o ppid= -p "$pid"
    ;;
esac
exit 1
SH
  chmod +x "$fakebin"/*
}

# build_world <name> <secondmate|primary>: a throwaway root whose bin/ is the
# real one, plus a home carrying a task record, a status log, backlog rows, and
# context files with distinctive bodies. Echoes root|home|fakebin.
build_world() {
  local name=$1 kind=$2 w root home fakebin
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  fakebin="$w/fakebin"
  mkdir -p "$root" "$home/state" "$home/data" "$home/config" "$home/projects" "$fakebin"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"
  printf '# Firstmate\n' > "$root/AGENTS.md"
  make_fakebin "$fakebin"
  [ "$kind" != secondmate ] || printf '%s\n' "$TASK_ID" > "$home/.fm-secondmate-home"
  printf '%s\n' manual > "$home/config/backlog-backend"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$$" > "$home/state/.lock.session"
  touch "$home/state/.last-watcher-beat"
  {
    printf 'window=firstmate:fm-%s\n' "$TASK_ID"
    printf 'endpoint_task_id=%s\n' "$TASK_ID"
    printf 'worktree=%s\n' "$home"
    printf 'project=%s\n' "$home"
    printf 'harness=pi\n'
    printf 'kind=secondmate\n'
    printf 'model=default\n'
    printf 'effort=default\n'
    printf 'tool_profile=monitor\n'
    printf 'META-BODY-MARKER=task-record-body\n'
  } > "$home/state/$TASK_ID.meta"
  printf 'done [at=1]: STATUS-BODY-MARKER\n' > "$home/state/$TASK_ID.status"
  cat > "$home/data/backlog.md" <<EOF
# Backlog

## In flight

- $TASK_ID - BACKLOG-BODY-MARKER

## Queued

- queued-item - BACKLOG-QUEUED-MARKER
EOF
  printf 'PROJECTS-BODY-MARKER\n' > "$home/data/projects.md"
  printf 'CAPTAIN-BODY-MARKER\n' > "$home/data/captain.md"
  printf 'LEARNINGS-BODY-MARKER\n' > "$home/data/learnings.md"
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

read_world() {
  IFS='|' read -r ROOT_DIR HOME_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_digest() {
  local extra_env=$1
  shift
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    $extra_env \
    FM_FAKE_HARNESS_PID="$$" \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT_DIR" \
    PATH="$FAKEBIN_DIR:$BASE_PATH" FM_SESSION_START_TIMEOUT=90 \
    "$SESSION_START" "$@" 2>&1
}

case_secondmate_home_prints_bounded_checkpoint() {
  local rec out
  rec=$(build_world mate secondmate)
  read_world "$rec"

  out=$(run_digest '')

  # Kept: the lock line, the wake queue state, and the checkpoint itself.
  assert_contains "$out" 'lock acquired' \
    "this case must exercise the locked path, not the read-only fallback"
  assert_contains "$out" 'LOCK' "the digest must keep the LOCK section"
  assert_contains "$out" 'WAKE QUEUE' "the digest must keep the WAKE QUEUE section"
  assert_contains "$out" 'Secondmate checkpoint' \
    "a secondmate home must print the bounded checkpoint"
  assert_contains "$out" 'FM_SESSION_START_FULL_DIGEST=1' \
    "the checkpoint must print the on-demand full-digest command"
  assert_contains "$out" 'fm-crew-state.sh' \
    "the checkpoint must print the per-task current-state command"
  assert_contains "$out" '<id>.meta' \
    "the checkpoint must print how to read one task record"

  # Dropped: the bulk a mate does not need in every request.
  assert_not_contains "$out" 'META-BODY-MARKER' \
    "a secondmate digest must not print a task record body"
  # The wake-queue drain may still present the newest status event as this
  # turn's work; what must not be reprinted is the fleet section's own per-task
  # status tail for every recorded task.
  assert_not_contains "$out" 'status tail (' \
    "a secondmate digest must not print the per-task status tails"
  assert_not_contains "$out" 'BACKLOG-BODY-MARKER' \
    "a secondmate digest must not print the backlog listing"
  assert_not_contains "$out" 'CAPTAIN-BODY-MARKER' \
    "a secondmate digest must not print the curated memory bodies"
  assert_not_contains "$out" 'LEARNINGS-BODY-MARKER' \
    "a secondmate digest must not print the learnings body"
  assert_not_contains "$out" 'PROJECTS-BODY-MARKER' \
    "a secondmate digest must not print the project registry body"

  # Presence facts still work, so absence is never confused with "not printed".
  assert_contains "$out" 'present,' \
    "the checkpoint must still state that a present context file is present"
  assert_contains "$out" 'data/secondmates.md' \
    "the checkpoint must still name every context file it did not print"
  assert_contains "$out" 'ABSENT' \
    "the checkpoint must still report the absent context file as ABSENT"

  pass "secondmate home: bounded checkpoint keeps lock, wake queue, and read commands"
}

case_primary_home_is_unchanged() {
  local rec out
  rec=$(build_world primary primary)
  read_world "$rec"

  out=$(run_digest '')

  assert_not_contains "$out" 'Secondmate checkpoint' \
    "a home without the secondmate marker must keep the full digest"
  assert_contains "$out" 'META-BODY-MARKER' \
    "a primary digest must still print the task record body"
  assert_contains "$out" 'CAPTAIN-BODY-MARKER' \
    "a primary digest must still print the curated memory body"
  assert_contains "$out" 'STATUS-BODY-MARKER' \
    "a primary digest must still print status-log tails"
  pass "primary home: the full digest is unchanged"
}

case_full_digest_escape() {
  local rec out
  rec=$(build_world mate-full secondmate)
  read_world "$rec"

  out=$(run_digest 'FM_SESSION_START_FULL_DIGEST=1')

  assert_not_contains "$out" 'Secondmate checkpoint' \
    "the escape must print the full digest instead of the checkpoint"
  assert_contains "$out" 'META-BODY-MARKER' \
    "the escape must print the task record listing a mate can still ask for"
  pass "escape: FM_SESSION_START_FULL_DIGEST=1 prints the full digest in a secondmate home"
}

case_secondmate_home_prints_bounded_checkpoint
case_primary_home_is_unchanged
case_full_digest_escape

echo "# all fm-session-start-secondmate-checkpoint tests passed"
