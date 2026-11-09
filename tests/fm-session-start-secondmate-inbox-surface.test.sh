#!/usr/bin/env bash
# tests/fm-session-start-secondmate-inbox-surface.test.sh - a secondmate's own
# session start must surface unhandled steering-inbox records without waiting
# for a watcher re-ring or a live re-send.
#
# The failure this pins: a steer written while the pane was down stays durable
# in state/<id>.inbox/001.msg, but a restarted mate's session start did not read
# it. The fix makes the mate's own start present every unhandled record body in
# numeric order. The handled/ move remains the acknowledgement, so the same path
# presents nothing once the record is handled.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SESSION_START="$ROOT/bin/fm-session-start.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-session-start-secondmate-inbox-surface)
TASK_ID=mateinbox-z1
INBOX_BODY=INBOX-BODY-MARKER
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

# build_world <name>: a throwaway root whose bin/ is the real one, plus a
# secondmate home carrying the marker, a task record, a status log, and a
# backlog. Echoes root|home|fakebin.
build_world() {
  local name=$1 w root home fakebin
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
  printf '%s\n' "$TASK_ID" > "$home/.fm-secondmate-home"
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
  } > "$home/state/$TASK_ID.meta"
  printf 'done [at=1]: STATUS-BODY-MARKER\n' > "$home/state/$TASK_ID.status"
  printf '%s\n' "$root|$home|$fakebin"
}

read_world() {
  IFS='|' read -r ROOT_DIR HOME_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_digest() {
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_FAKE_HARNESS_PID="$$" \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT_DIR" \
    PATH="$FAKEBIN_DIR:$BASE_PATH" FM_SESSION_START_TIMEOUT=90 \
    "$SESSION_START" "$@" 2>&1
}

write_inbox_record() {
  local state=$1 task=$2 body=$3
  bash -c '. "$1"; fm_task_inbox_write "$2" "$3" "$4"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$state" "$task" "$body"
}

case_unhandled_inbox_is_surfaced_at_session_start() {
  local rec out record
  rec=$(build_world surfaced)
  read_world "$rec"

  record=$(write_inbox_record "$HOME_DIR/state" "$TASK_ID" "$INBOX_BODY") \
    || fail "could not write the fixture inbox record"
  [ "$record" = "$HOME_DIR/state/$TASK_ID.inbox/001.msg" ] \
    || fail "fixture record should be 001.msg, got $record"

  out=$(run_digest)

  assert_contains "$out" 'STEERING INBOX' \
    "a secondmate session start must print the steering-inbox section"
  assert_contains "$out" "$INBOX_BODY" \
    "a secondmate session start must present the unhandled record body"
  assert_contains "$out" "$record" \
    "the surfaced record must identify the durable record it read"
  pass "secondmate session start surfaces an unhandled steering-inbox record"
}

case_handled_record_is_not_surfaced() {
  local rec out record
  rec=$(build_world handled)
  read_world "$rec"

  record=$(write_inbox_record "$HOME_DIR/state" "$TASK_ID" "$INBOX_BODY") \
    || fail "could not write the fixture inbox record"
  mv "$record" "$HOME_DIR/state/$TASK_ID.inbox/handled/"

  out=$(run_digest)

  assert_not_contains "$out" "$INBOX_BODY" \
    "a handled record must not be presented by session start"
  assert_not_contains "$out" "$record" \
    "a handled record's root path must not be presented"
  assert_contains "$out" '(no unhandled firstmate instructions)' \
    "the empty steering inbox must be named as empty"
  pass "secondmate session start presents nothing for a handled record"
}

case_unhandled_inbox_is_surfaced_at_session_start
case_handled_record_is_not_surfaced

echo "# all fm-session-start-secondmate-inbox-surface tests passed"
