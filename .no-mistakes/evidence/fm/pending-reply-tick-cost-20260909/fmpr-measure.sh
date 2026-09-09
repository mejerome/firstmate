#!/usr/bin/env bash
# Before/after measurement harness for the fm_pending_reply_tick settled-record
# fast path (bin/fm-pending-reply-lib.sh).
#
# The same fixture store (2283 fully settled records, mirroring the production
# retained store) is ticked once with the BASE implementation and once with the
# TARGET implementation. For each pass we record wall-clock time, the number of
# fm_pending_reply_get record reads (each one is a $( ) subshell over a
# grep|tail|cut subprocess chain), and the number of close_escalation calls
# (each takes the per-correlation lock and sources bin/fm-wake-lib.sh).
# Counters are appended to a file because fm_pending_reply_get runs inside
# command substitutions (forked subshells) whose variable writes are lost.
set -u
W=/root/.no-mistakes/worktrees/5810ae86d8a1/01M224RAN2FN3579BPCB2VMT5G
BASE_LIB_DIR="$1"            # directory holding the BASE fm-pending-reply-lib.sh + sibling bin files
N="${2:-2283}"               # number of settled records in the store
OUT="$3"                     # raw transcript output file
EVD="$(cd "$(dirname "$0")" && pwd)"

. "$W/tests/lib.sh"
. "$W/bin/fm-marker-lib.sh"
. "$W/bin/fm-pending-reply-lib.sh"

export FM_PENDING_REPLY_GRACE_SECS=0
export FM_SEND_SETTLE=0

TMP="$(mktemp -d /tmp/fmpr-measure.XXXXXX)" || exit 1
if [ "${FM_KEEP:-}" != 1 ]; then trap 'rm -rf "$TMP" "$EVD/.fmpr-base-bin"' EXIT; fi
echo "fixture root: $TMP"

# --- fixture: one real, fully settled record (resolved, escalation closed) ---
golden_home="$TMP/golden"
mkdir -p "$golden_home/state"
export FM_PENDING_REPLY_NOW=12000
g_state="$golden_home/state"
g_corr=$(fm_pending_reply_create "$golden_home" "$g_state" hibit "settled request") || exit 1
fm_pending_reply_mark_delivered "$g_state" "$g_corr"
g_rec=$(fm_pending_reply_path "$g_state" "$g_corr")
fm_pending_reply_set "$g_rec" phase escalated
fm_pending_reply_set "$g_rec" escalated_epoch 12000
printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=hibit pending-reply-id=%s request=settled request\n' "$g_corr" "$g_corr" > "$g_state/hibit.status"
printf 'done [corr=%s]: late reply\n' "$g_corr" >> "$g_state/hibit.status"
fm_pending_reply_try_resolve "$g_state" "$g_corr" || exit 1
[ "$(fm_pending_reply_get "$g_rec" phase)" = resolved ] || exit 1
[ -n "$(fm_pending_reply_get "$g_rec" escalation_closed_epoch)" ] || exit 1
echo "golden settled record $g_corr phase=$(fm_pending_reply_get "$g_rec" phase) escalated=$(fm_pending_reply_get "$g_rec" escalated_epoch) closed=$(fm_pending_reply_get "$g_rec" escalation_closed_epoch)"

# --- build N identical settled stores ----------------------------------------
mk_settled_store() {  # <dir> -> fills dir/state/pending-replies
  local store=$1 corr i line
  mkdir -p "$store/state/pending-replies"
  i=0
  while [ "$i" -lt "$N" ]; do
    corr=$(printf '%016x' "$(( 9000000000 + i ))")
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        corr_id=*) printf 'corr_id=%s\n' "$corr" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$g_rec" > "$store/state/pending-replies/$corr"
    i=$((i + 1))
  done
}
store_a="$TMP/store-settled-a"
store_b="$TMP/store-settled-b"
mk_settled_store "$store_a"
cp -a "$store_a" "$store_b"
echo "settled stores built: $(find "$store_a/state/pending-replies" -maxdepth 1 -type f | wc -l) records each"

# --- instrumented tick runner ------------------------------------------------
# Run fm_pending_reply_tick over <state> in a fresh bash sourcing <libfile>.
# fm_pending_reply_get reads, fm_pending_reply_close_escalation calls
# (per-correlation lock acquisitions) and fm_pending_reply_tick_capture passes
# are counted by appending one line per call to a counter file (subshell-safe).
run_tick() {  # <libdir> <state> <label>
  local libdir=$1 state=$2 label=$3 out cnt
  out="$TMP/$label.out"
  cnt="$TMP/$label.cnt"
  : > "$cnt"
  FM_ROOT_OVERRIDE="$TMP/fakehome" FM_HOME="$TMP/fakehome" FM_PR_COUNT_FILE="$cnt" \
  bash -s "$libdir" "$state" "$label" > "$out" 2>&1 <<'SH'
set -u
libdir=$1 state=$2 label=$3
cnt=${FM_PR_COUNT_FILE:?}
# shellcheck disable=SC1091
. "$libdir/fm-pending-reply-lib.sh"
# Rename each instrumented function and install a counting wrapper; counts are
# appended to $cnt so increments inside $( ) subshells are not lost.
eval "$(declare -f fm_pending_reply_get | sed '1s/^fm_pending_reply_get /fm_pending_reply_get_orig /')"
fm_pending_reply_get() { printf 'get\n' >> "$cnt"; fm_pending_reply_get_orig "$@"; }
eval "$(declare -f fm_pending_reply_close_escalation | sed '1s/^fm_pending_reply_close_escalation /fm_pending_reply_close_escalation_orig /')"
fm_pending_reply_close_escalation() { printf 'close\n' >> "$cnt"; fm_pending_reply_close_escalation_orig "$@"; }
if declare -F fm_pending_reply_tick_capture >/dev/null 2>&1; then
  eval "$(declare -f fm_pending_reply_tick_capture | sed '1s/^fm_pending_reply_tick_capture /fm_pending_reply_tick_capture_orig /')"
  fm_pending_reply_tick_capture() { printf 'cap\n' >> "$cnt"; fm_pending_reply_tick_capture_orig "$@"; }
fi
t0=${EPOCHREALTIME/./}
fm_pending_reply_tick "$state" || { echo "tick FAILED"; exit 1; }
t1=${EPOCHREALTIME/./}
# EPOCHREALTIME is seconds with 6 fractional digits (microseconds).
elapsed_ms=$(( (10#$t1 - 10#$t0) / 1000 ))
get_count=$(grep -Fc 'get' "$cnt" 2>/dev/null || true)
close_count=$(grep -Fc 'close' "$cnt" 2>/dev/null || true)
cap_count=$(grep -Fc 'cap' "$cnt" 2>/dev/null || true)
printf '%s get_calls=%d close_calls=%d capture_passes=%d elapsed_ms=%d\n' "$label" "$get_count" "$close_count" "$cap_count" "$elapsed_ms"
SH
  cat "$out"
}

echo "=== instrumented tick passes over the SAME settled store ($N records) ==="
run_tick "$BASE_LIB_DIR" "$store_a/state" "BEFORE(base)"
run_tick "$W/bin" "$store_b/state" "AFTER(target)"
# A second AFTER pass (steady state: each pass must stay cheap).
run_tick "$W/bin" "$store_b/state" "AFTER(target)-pass2"

# Builtin-only proof: the settled store must tick with no external subprocess at all.
echo "=== builtin-only proof: settled tick with PATH stripped (target) ==="
FM_ROOT_OVERRIDE="$TMP/fakehome" FM_HOME="$TMP/fakehome" \
bash -c '
  set -u
  # shellcheck disable=SC1091
  . "$1/fm-pending-reply-lib.sh"
  PATH=/nonexistent
  fm_pending_reply_tick "$2" && echo "settled tick OK with PATH stripped" || echo "settled tick FAILED with PATH stripped"
' _ "$W/bin" "$store_b/state"

echo "=== open-escalation convergence: same behavior before and after ==="
# A store holding three resolved records whose escalation close was deferred
# (escalation_closed_epoch empty), mirroring tests/fm-pending-reply.test.sh:
# the tick must still close each one exactly once under the per-correlation lock.
store_c="$TMP/store-open-before"
store_d="$TMP/store-open-after"
mkdir -p "$store_c/state/pending-replies"
make_open_record() {  # <state> <seed> <now> -> corr
  local state=$1 seed=$2 now=$3 corr rec open_status
  corr=$(FM_PENDING_REPLY_NOW=$now fm_pending_reply_create "$(dirname "$state")" "$state" hibit "converge close") || return 1
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  fm_pending_reply_set "$rec" phase escalated
  fm_pending_reply_set "$rec" escalated_epoch $((now - 100))
  open_status="$state/hibit.status"
  # Real parent statuses accumulate lines over time: append each record's lines.
  printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=hibit pending-reply-id=%s request=converge close\n' "$corr" "$corr" >> "$open_status"
  printf 'done [corr=%s]: late reply\n' "$corr" >> "$open_status"
  fm_pending_reply_set "$rec" parent_status ""
  FM_PENDING_REPLY_NOW=$now fm_pending_reply_try_resolve "$state" "$corr" "$open_status" || return 1
  [ "$(fm_pending_reply_get "$rec" phase)" = resolved ] || return 1
  if [ -n "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ]; then return 1; fi
  fm_pending_reply_set "$rec" parent_status "$open_status" || return 1
  printf '%s' "$corr"
}
for seed in 1 2 3; do
  corr=$(make_open_record "$store_c/state" "$seed" $((13000 + seed))) || exit 1
  echo "open-escalation fixture seed=$seed corr=$corr (resolved, escalation still open)"
done
cp -a "$store_c" "$store_d"
# Records carry an absolute parent_status written at create time; repoint each
# copied record at its own store so each tick closes into its own status file.
for rec in "$store_d/state/pending-replies"/*; do
  [ -f "$rec" ] || continue
  sed -i "s|^parent_status=.*|parent_status=$store_d/state/hibit.status|; s|^parent_home=.*|parent_home=$store_d|" "$rec"
done
echo "-- BEFORE(base) tick over the open-escalation store --"
FM_ROOT_OVERRIDE="$TMP/fakehome" FM_HOME="$TMP/fakehome" \
bash -s "$BASE_LIB_DIR" "$store_c/state" "BEFORE(base)" <<'SH' 2>&1
set -u
# shellcheck disable=SC1091
. "$1/fm-pending-reply-lib.sh"
t0=${EPOCHREALTIME/./}
fm_pending_reply_tick "$2" || { echo "base converge tick FAILED"; exit 1; }
t1=${EPOCHREALTIME/./}
printf 'BEFORE(base) open-escalation tick OK elapsed_ms=%d\n' "$(( (10#$t1 - 10#$t0) / 1000 ))"
SH
echo "-- AFTER(target) tick over the identical open-escalation store --"
FM_ROOT_OVERRIDE="$TMP/fakehome" FM_HOME="$TMP/fakehome" \
bash -s "$W/bin" "$store_d/state" "AFTER(target)" <<'SH' 2>&1
set -u
# shellcheck disable=SC1091
. "$1/fm-pending-reply-lib.sh"
t0=${EPOCHREALTIME/./}
fm_pending_reply_tick "$2" || { echo "target converge tick FAILED"; exit 1; }
t1=${EPOCHREALTIME/./}
printf 'AFTER(target) open-escalation tick OK elapsed_ms=%d\n' "$(( (10#$t1 - 10#$t0) / 1000 ))"
SH

# Verify both stores converged identically: escalation_closed_epoch set and the
# guarded decision close appended exactly once per record.
echo "-- verify convergence equality (escalation_closed_epoch set, decision closed exactly once) --"
verify_store() {  # <store> <label>
  local store=$1 label=$2 state="$1/state" rec corr status n ok=1
  for rec in "$state/pending-replies"/*; do
    [ -f "$rec" ] || continue
    corr=$(sed -n 's/^corr_id=//p' "$rec" | tail -1)
    status="$state/hibit.status"
    if [ -z "$(sed -n 's/^escalation_closed_epoch=//p' "$rec" | tail -1)" ]; then
      echo "$label corr=$corr MISSING escalation_closed_epoch"; ok=0; continue
    fi
    n=$(grep -Fc "resolved [key=pending-reply-$corr]: pending-reply-resolved:" "$status" 2>/dev/null || true)
    if [ "$n" != 1 ]; then echo "$label corr=$corr expected exactly 1 decision close, found $n"; ok=0; continue; fi
    echo "$label corr=$corr CONVERGED (escalation_closed_epoch set, 1 decision close)"
  done
  [ "$ok" = 1 ]
}
verify_store "$store_c" "BEFORE(base)" || exit 1
verify_store "$store_d" "AFTER(target)" || exit 1
echo "ALL MEASUREMENTS DONE"
