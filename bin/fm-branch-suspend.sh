#!/usr/bin/env bash
# fm-branch-suspend.sh - the one explicit, firstmate-invocable way to stand the
# Pi supervision branch down in place (docs/pi-supervision-branch.md
# "Integrity suspension").
#
# WHY. An integrity failure in the branch conversation must be contained
# without restarting the captain's primary session and without changing the
# away or quiet posture. Suspension leaves MAIN as the only supervision actor:
# every wake that would have been offered to the branch stays on main's normal
# path, and nothing about the captain's authority or the away record changes.
#
# CONTRACT.
#   - Record: $STATE/.branch-suspended, written atomically with mode 0600:
#       schema=fm-branch-suspension.v1
#       suspended=<epoch>
#       actor=<main|branch>
#       reason=<one line>
#     Presence is the fact the dispatch handshake
#     (.pi/extensions/lib/fm-branch-dispatch.ts) reads at every offer. A
#     malformed or truncated record is still presence, so a failed write cannot
#     silently re-enable the branch; `status` reports that fault.
#   - Actors: only MAIN (the firstmate itself) may suspend or resume. The
#     supervision branch is refused through bin/fm-lease-lib.sh, so a branch
#     that has lost integrity cannot stand itself down or back up. A home with
#     no branch is unchanged: the script is inert until firstmate invokes it.
#   - Suspension is not a posture. It grants no authority, archives no captain
#     words, and never changes which actor may merge, spawn, answer, or tear
#     down. Away and quiet semantics remain owned by bin/fm-afk-contract.sh.
#
# Usage:
#   fm-branch-suspend.sh suspend --reason <one-line reason>
#   fm-branch-suspend.sh resume
#   fm-branch-suspend.sh status
#
# Exit codes: 0 success; 1 a record fault; 2 usage; FM_LEASE_REFUSE_EXIT when
# the branch actor tries to suspend or resume.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.branch-suspended"
SCHEMA=fm-branch-suspension.v1

# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

clean_reason() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177'
}

record_field() {  # <name>
  sed -n "s/^$1=//p" "$RECORD" 2>/dev/null | head -1
}

record_is_regular() {
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ]
}

write_record() {  # <reason>
  local reason=$1 tmp actor=${FM_SUPERVISION_ACTOR:-main} now
  now=$(date +%s)
  (umask 077; mkdir -p "$STATE") || {
    echo "error: cannot prepare $STATE for a supervision-branch suspension record" >&2
    return 1
  }
  tmp=$(mktemp "$STATE/.branch-suspended.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! {
    printf 'schema=%s\n' "$SCHEMA"
    printf 'suspended=%s\n' "$now"
    printf 'actor=%s\n' "$actor"
    printf 'reason=%s\n' "$reason"
  } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

command_suspend() {
  local reason=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -n "$reason" ] || {
    echo "error: suspend requires --reason so the session-start digest and fm-crew-state.sh can name why the branch is down" >&2
    exit 2
  }
  fm_lease_forbid_branch "supervision-branch suspension"
  reason=$(clean_reason "$reason")
  [ -n "$reason" ] || {
    echo "error: suspend reason is empty after removing control characters" >&2
    exit 2
  }
  write_record "$reason" || {
    echo "error: could not write the supervision-branch suspension record at $RECORD" >&2
    exit 1
  }
  printf 'suspended: %s\n' "$reason"
}

command_resume() {
  [ "$#" -eq 0 ] || usage
  fm_lease_forbid_branch "supervision-branch resume"
  if [ -L "$RECORD" ] || { [ -e "$RECORD" ] && [ ! -f "$RECORD" ]; }; then
    echo "error: refusing to remove an unsafe suspension record at $RECORD; inspect it by hand" >&2
    exit 1
  fi
  rm -f -- "$RECORD"
  printf 'active: supervision branch may take eligible wakes again\n'
}

command_status() {
  [ "$#" -eq 0 ] || usage
  if [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ]; then
    printf 'state: active\n'
    return 0
  fi
  if ! record_is_regular; then
    printf 'state: suspended\n'
    printf 'record: unreadable or unsafe (%s)\n' "$RECORD"
    printf 'reason: the branch stays down until firstmate inspects and removes the record\n'
    return 1
  fi
  local schema suspended actor reason
  schema=$(record_field schema)
  suspended=$(record_field suspended)
  actor=$(record_field actor)
  reason=$(record_field reason)
  printf 'state: suspended\n'
  [ -z "$suspended" ] || printf 'since: %s\n' "$suspended"
  [ -z "$actor" ] || printf 'by: %s\n' "$actor"
  [ -z "$reason" ] || printf 'reason: %s\n' "$reason"
  if [ "$schema" != "$SCHEMA" ]; then
    printf 'record: malformed (schema %s, expected %s)\n' "${schema:-missing}" "$SCHEMA"
    return 1
  fi
  return 0
}

case "${1:-}" in
  suspend) shift; command_suspend "$@" ;;
  resume) shift; command_resume "$@" ;;
  status) shift; command_status "$@" ;;
  *) usage ;;
esac
