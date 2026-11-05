#!/usr/bin/env bash
# fm-authority-lib.sh - the one owner of captain-authority verification for an
# outbound firstmate action or worker steer.
#
# WHY. A ruling is evidence only when the captain actually said it and a
# durable record holds those words. Conversation text, the MAIN dialog mirror,
# a status line, an inbox record, or a plausible-looking SHA is never evidence.
# The 2026-09-09 incident invented a captain ruling and put it into a worker's
# steering inbox through bin/fm-send.sh; this guard is the deterministic stop
# for that class of claim.
#
# CONTRACT.
#   - The durable record is the resolution block written by
#     bin/fm-captain-hold.sh answer or answers, read back through its
#     `recorded-answer` subcommand. A task held through the tasks-axi path is
#     read from the same configured backlog, so both owners are covered.
#   - A steering message is attributable only when it carries the established
#     from-firstmate marker owned by bin/fm-operational-input.sh
#     ([fm-from-firstmate] plus U+2063). A message that cites captain authority
#     without that marker is refused even when a record exists.
#   - `fm_authority_text_claims_captain` is deliberately conservative: it
#     recognizes the ordinary ways an actor attributes a decision to the
#     captain, so a false negative still leaves the guard available through the
#     explicit record argument. It is not a general prose classifier.
#
# No side effects on source. Bash 3.2 compatible. set -u safe.
set -u

_FM_AUTHORITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-operational-input.sh
. "$_FM_AUTHORITY_LIB_DIR/fm-operational-input.sh"

# fm_authority_text_claims_captain <text>: 0 when <text> attributes a decision,
# ruling, answer, approval, or instruction to the captain. The caller still owns
# what to do with that fact; this function never reads a record or a transcript.
fm_authority_text_claims_captain() {
  local text=${1-}
  [ -n "$text" ] || return 1
  printf '%s' "$text" | grep -Eiq \
    "(^|[^[:alnum:]_])captain('s)?[[:space:]]+(decision|answer|ruling|word|call|approval|authorization|authorisation)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])captain('s)?[[:space:]]+(said|says|approved|approves|authorized|authorised|confirmed|confirms|decided|decides|ruled|rules|answered|answers|directed|directs|instructed|instructs|chose|chooses|wants|wanted|asked|asks|told|tells|agreed|agrees|gave|gives|issued|issues)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])ruling[[:space:]]+(is[[:space:]]+)?(in|received|confirmed|given)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])per[[:space:]]+the[[:space:]]+captain([^[:alnum:]_]|$)|(^|[^[:alnum:]_])captain[-[:space:]](approved|authorized|authorised|confirmed|directed|instructed)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])on[[:space:]]+the[[:space:]]+captain('s)?[[:space:]]+(authority|word|say-so)([^[:alnum:]_]|$)"
}

# fm_authority_require_marked <message> [<action-label>]: 0 only when the
# message carries the from-firstmate marker. The label names the refused action
# in the diagnostic.
fm_authority_require_marked() {
  local message=${1-} label=${2:-captain-authority action}
  if fm_message_from_firstmate "$message"; then
    return 0
  fi
  printf 'error: %s refused - captain-attributed authority requires the [fm-from-firstmate] marker; an unmarked message, mirror, status line, or inbox record is never evidence of a captain decision\n' "$label" >&2
  return 4
}

# fm_authority_recorded_answer <task-id>: print the durable record line from
# bin/fm-captain-hold.sh recorded-answer. Any read failure is a refusal, not a
# guess: a missing task, a closed call with no captain-answer resolution, or an
# unreadable backlog all print nothing and return nonzero.
fm_authority_recorded_answer() {
  local id=${1-} hold_bin
  [ -n "$id" ] || return 1
  hold_bin=${FM_AUTHORITY_CAPTAIN_HOLD_BIN:-$_FM_AUTHORITY_LIB_DIR/fm-captain-hold.sh}
  [ -x "$hold_bin" ] || return 1
  "$hold_bin" recorded-answer "$id" 2>/dev/null
}

# fm_authority_require_captain <message> <task-id> [<action-label>]: the full
# gate for a message that cites a captain decision. It verifies, in order, the
# from-firstmate marker and then a durable captain-answer record for the named
# task. Every failure prints a refusal that says exactly what is missing, and
# exits 4 so callers can distinguish it from usage and transport errors.
fm_authority_require_captain() {
  local message=${1-} id=${2-} label=${3:-captain-authority action}
  fm_authority_text_claims_captain "$message" || return 0
  fm_authority_require_marked "$message" "$label" || return 4
  if [ -z "$id" ]; then
    printf 'error: %s refused - no captain answer on record: the message cites a captain decision but names no captain-held task with a recorded answer; answer the call first with bin/fm-captain-hold.sh answer, then pass its task id\n' "$label" >&2
    return 4
  fi
  if ! fm_authority_recorded_answer "$id" >/dev/null; then
    printf 'error: %s refused - no captain answer on record for task %s: bin/fm-captain-hold.sh recorded-answer found no captain-answer resolution block, so transcript, mirror, status-line, and inbox text are not evidence\n' "$label" "$id" >&2
    return 4
  fi
  return 0
}

# fm_authority_require_record <task-id> [<action-label>]: the record half of the
# gate for a caller that already declares captain authority explicitly (for
# example an fm-send --captain-answer argument) even when the text does not
# trigger the prose check. Marker verification remains separate so the caller
# can construct the wire message first.
fm_authority_require_record() {
  local id=${1-} label=${2:-captain-authority action}
  if [ -z "$id" ]; then
    printf 'error: %s refused - no captain answer on record: no captain-held task was named\n' "$label" >&2
    return 4
  fi
  if ! fm_authority_recorded_answer "$id" >/dev/null; then
    printf 'error: %s refused - no captain answer on record for task %s: bin/fm-captain-hold.sh recorded-answer found no captain-answer resolution block, so transcript, mirror, status-line, and inbox text are not evidence\n' "$label" "$id" >&2
    return 4
  fi
  return 0
}
