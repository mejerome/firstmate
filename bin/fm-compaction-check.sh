#!/usr/bin/env bash
# fm-compaction-check.sh - resolve the compaction trigger point of the pi
# sessions firstmate launches, and fail loudly when one is mis-sized.
#
# Usage:
#   fm-compaction-check.sh                print one line per session scope
#   fm-compaction-check.sh --all          same as above (explicit)
#   fm-compaction-check.sh --diagnostics  print only the mis-sizing verdicts
#                                         (silent unless a scope is unsafe)
#
# THE ARITHMETIC (single owner: this file, function trigger_percent):
#   trigger_percent = (contextWindow - reserveTokens) / contextWindow * 100
# That is pi's own rule: pi compacts when
# contextTokens > contextWindow - reserveTokens, so reserveTokens is the margin
# held back below the window and the trigger point is where the window runs out
# of room for the answer. A too-small reserve therefore means "compaction fires
# too late" (effectively never, for a large window), and a reserve at or above
# the window means "compaction fires on every turn".
#
# SCOPE AND RESOLUTION
# One line per session scope firstmate launches:
#   primary        the firstmate primary session, cwd = the primary home.
#   global-scope   the pairing a session receives in a cwd with no project
#                  .pi/settings.json (firstmate launches crewmates into such
#                  worktrees), reported from the global settings file's own
#                  defaultProvider/defaultModel and reserveTokens.
#   secondmate-<id>  one per entry in the primary home's data/secondmates.md,
#                  cwd = that entry's home, model = the shared
#                  config/secondmate-harness pin ("<harness> [<model>] [<effort>]").
# A session's model follows pi's own settings precedence: the session cwd's
# .pi/settings.json over the global settings.json, merged key by key. The
# effective reserveTokens follows the same precedence over the same pair.
# Context windows are read from `pi --list-models`; no window is hardcoded.
# Project trust is assumed: pi ignores an untrusted project's settings, and
# firstmate relies on ~/.pi/agent/trust.json covering its homes (the standing
# setup carries a "/" entry, which pi's nearest-ancestor lookup applies to every
# home). A non-pi secondmate harness is skipped, because pi's compaction
# settings do not govern it. A host with no pi installed is skipped too: the
# check cannot say anything about a fleet that launches no pi sessions, and its
# noisy failure would be a permanent false alarm there.
#
# VERDICTS
#   ok        trigger point is above 0% and at or below the limit
#   unsafe    trigger point is above the limit (reason=trigger-above-limit), or
#             the reserve is not below the window at all
#             (reason=reserve-not-below-window), which compacts every turn
#   skipped   the scope is not a pi session (reason=harness-not-pi), or this host
#             has no pi to launch at all (reason=pi-not-installed), so pi's
#             compaction settings govern nothing here
#   error     the scope could not be resolved (missing model, unknown or
#             ambiguous model id, unreadable settings, model list unavailable)
#
# Exit status: 0 every scope ok or skipped, 1 at least one unsafe, 2 at least one error.
#
# --diagnostics is the session-start digest's view: it carries exactly the
# mis-sizing verdicts, so the digest stays silent until a scope is unsafe. Every
# other outcome (skipped, error) stays visible in --all, and an unreadable input
# still exits 2 there, because a check that cannot run is an operator problem
# rather than a fleet defect the digest should repeat at every session start.
#
# INPUTS (every one overridable so tests and fixtures can substitute them):
#   FM_COMPACTION_GLOBAL_SETTINGS   default ${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/settings.json
#   FM_COMPACTION_PRIMARY_HOME      default $FM_HOME, else the parent recorded in
#                                   $FM_HOME/.fm-secondmate-parent
#   FM_COMPACTION_SECONDMATES_FILE  default <primary home>/data/secondmates.md
#   FM_COMPACTION_HARNESS_FILE      default <primary home>/config/secondmate-harness
#   FM_COMPACTION_MODELS_CMD        default "pi --no-extensions --offline --list-models"
#                                   (splits on whitespace; --offline and
#                                   --no-extensions keep it fast and quiet on the
#                                   session-start critical path)
#   FM_COMPACTION_MAX_TRIGGER_PERCENT  default 60
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

DEFAULT_MAX_TRIGGER_PERCENT=60
PI_DEFAULT_RESERVE_TOKENS=16384
CONFIG_DIR_NAME=.pi

MODE=all
VERDICT_WORST=0

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

die_usage() {
  printf 'fm-compaction-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) MODE=all ;;
    --diagnostics) MODE=diagnostics ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

# --- inputs -----------------------------------------------------------------

GLOBAL_SETTINGS=${FM_COMPACTION_GLOBAL_SETTINGS:-${PI_CODING_AGENT_DIR:-${HOME:-}/.pi/agent}/settings.json}
DEFAULT_MODELS_CMD="pi --no-extensions --offline --list-models"
MODELS_CMD=${FM_COMPACTION_MODELS_CMD:-$DEFAULT_MODELS_CMD}
MAX_TRIGGER_PERCENT=${FM_COMPACTION_MAX_TRIGGER_PERCENT:-$DEFAULT_MAX_TRIGGER_PERCENT}

case "$MAX_TRIGGER_PERCENT" in
  ''|*[!0-9.]*) die_usage "FM_COMPACTION_MAX_TRIGGER_PERCENT must be a positive number" ;;
esac
awk -v m="$MAX_TRIGGER_PERCENT" 'BEGIN { exit !(m > 0) }' \
  || die_usage "FM_COMPACTION_MAX_TRIGGER_PERCENT must be a positive number"

# The primary home whose secondmate registry and harness pin are authoritative.
# A secondmate home records its parent in .fm-secondmate-parent, so a check run
# there still audits the whole fleet's primary-owned configuration.
PRIMARY_HOME=${FM_COMPACTION_PRIMARY_HOME:-}
if [ -z "$PRIMARY_HOME" ]; then
  PRIMARY_HOME=$FM_HOME
  parent_marker="$FM_HOME/.fm-secondmate-parent"
  if [ -f "$parent_marker" ]; then
    parent_home=$(sed -n 's/^parent_home=//p' "$parent_marker" | head -1)
    if [ -n "$parent_home" ] && [ -d "$parent_home" ]; then
      PRIMARY_HOME=$parent_home
    fi
  fi
fi
SECONDMATES_FILE=${FM_COMPACTION_SECONDMATES_FILE:-$PRIMARY_HOME/data/secondmates.md}
HARNESS_FILE=${FM_COMPACTION_HARNESS_FILE:-$PRIMARY_HOME/config/secondmate-harness}

# --- verdict bookkeeping ----------------------------------------------------

bump_verdict() {
  case "$1" in
    error) VERDICT_WORST=2 ;;
    unsafe) [ "$VERDICT_WORST" -eq 2 ] || VERDICT_WORST=1 ;;
  esac
}

# print_line <verdict> <name> <cwd> <model> <window> <reserve> <source> [<reason>] [<detail>]
print_line() {
  local verdict=$1 name=$2 cwd=$3 model=$4 window=$5 reserve=$6 source=$7
  local reason=${8:-} detail=${9:-} suffix=
  bump_verdict "$verdict"
  if [ "$MODE" = diagnostics ] && [ "$verdict" != unsafe ]; then
    return 0
  fi
  if [ -n "$reason" ]; then
    suffix=" reason=$reason"
  fi
  if [ -n "$detail" ]; then
    suffix="$suffix ($detail)"
  fi
  printf 'COMPACTION: %s session=%s cwd=%s model=%s window=%s reserveTokens=%s source=%s%s\n' \
    "$verdict" "$name" "$cwd" "$model" "$window" "$reserve" "$source" "$suffix"
}

# --- model list -------------------------------------------------------------

MODEL_RAW=
MODEL_TABLE=
MODELS_ERROR=
MODELS_NOT_APPLICABLE=

# Read `pi --list-models` once and turn it into provider|model|tokens|display.
# The context column is printed with decimal suffixes (131.1K is 131072 rounded
# to four significant figures), so K is 1000 and M is 1000000 here.
# Returns 0 with a table, 2 when the check does not apply because this host has no
# pi to launch (unset MODELS_NOT_APPLICABLE names why), and 1 on a real failure.
load_model_table() {
  local -a argv=()
  MODEL_TABLE=
  MODELS_ERROR=
  MODELS_NOT_APPLICABLE=
  if [ "$MODELS_CMD" = "$DEFAULT_MODELS_CMD" ] && ! command -v pi >/dev/null 2>&1; then
    MODELS_NOT_APPLICABLE="pi-not-installed"
    return 2
  fi
  # shellcheck disable=SC2206 # intentional word split: the override is a command line
  argv=($MODELS_CMD)
  if [ "${#argv[@]}" -eq 0 ]; then
    MODELS_ERROR="empty-model-list-command"
    return 1
  fi
  if ! MODEL_RAW=$("${argv[@]}" 2>/dev/null) || [ -z "$MODEL_RAW" ]; then
    MODELS_ERROR="model-list-command-failed"
    return 1
  fi
  MODEL_TABLE=$(printf '%s\n' "$MODEL_RAW" | awk '
    function to_tokens(value,  n) {
      n = value
      if (value ~ /[Kk]$/) { sub(/[Kk]$/, "", n); return int(n * 1000 + 0.5) }
      if (value ~ /[Mm]$/) { sub(/[Mm]$/, "", n); return int(n * 1000000 + 0.5) }
      if (value ~ /^[0-9]+$/) return int(n)
      return 0
    }
    NR == 1 && $1 == "provider" { next }
    NF >= 3 && $1 ~ /[^[:space:]]/ {
      tokens = to_tokens($3)
      if (tokens > 0) printf "%s|%s|%d|%s\n", $1, $2, tokens, $3
    }
  ')
  if [ -z "$MODEL_TABLE" ]; then
    MODELS_ERROR="model-list-command-printed-no-usable-rows"
    return 1
  fi
  return 0
}

# window_row <provider> <model> -> "tokens|display" when the row exists
window_row() {
  printf '%s\n' "$MODEL_TABLE" | awk -F'|' -v p="$1" -v m="$2" '$1 == p && $2 == m { print $3 "|" $4; exit }'
}

# model_rows <model> -> "provider|tokens|display" for every provider serving it
model_rows() {
  printf '%s\n' "$MODEL_TABLE" | awk -F'|' -v m="$1" '$2 == m { print $1 "|" $3 "|" $4 }'
}

# resolve_window <provider|""> <model> -> WINDOW_TOKENS WINDOW_DISPLAY WINDOW_ERROR
resolve_window() {
  local provider=$1 model=$2 rows count
  WINDOW_TOKENS=
  WINDOW_DISPLAY=
  WINDOW_ERROR=
  if [ -n "$provider" ]; then
    rows=$(window_row "$provider" "$model")
    if [ -z "$rows" ]; then
      case "$model" in
        */*)
          # Both a bare pi model id and a "provider/id" spec appear in firstmate
          # configuration, so retry the split form before failing.
          rows=$(window_row "${model%%/*}" "${model#*/}")
          ;;
      esac
    fi
    if [ -z "$rows" ]; then
      WINDOW_ERROR="model-not-in-pi-model-list"
      return 1
    fi
    WINDOW_TOKENS=${rows%%|*}
    WINDOW_DISPLAY=${rows#*|}
    return 0
  fi
  rows=$(model_rows "$model")
  count=$(printf '%s\n' "$rows" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    WINDOW_ERROR="model-not-in-pi-model-list"
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    WINDOW_ERROR="model-id-ambiguous"
    return 1
  fi
  WINDOW_TOKENS=$(printf '%s\n' "$rows" | cut -d'|' -f2)
  WINDOW_DISPLAY=$(printf '%s\n' "$rows" | cut -d'|' -f3)
  return 0
}

# --- settings ---------------------------------------------------------------

GLOBAL_JSON='{}'
PROJECT_JSON='{}'
PROJECT_SETTINGS_PATH=
SETTINGS_ERROR=

# read_json_file <path> -> compact JSON on stdout; absent file yields {}
read_json_file() {
  [ -f "$1" ] || { printf '%s' '{}'; return 0; }
  jq -c . "$1" 2>/dev/null || return 1
}

# load_settings_pair <cwd> -> GLOBAL_JSON, PROJECT_JSON, PROJECT_SETTINGS_PATH
load_settings_pair() {
  local cwd=$1
  PROJECT_SETTINGS_PATH="$cwd/$CONFIG_DIR_NAME/settings.json"
  SETTINGS_ERROR=
  if ! GLOBAL_JSON=$(read_json_file "$GLOBAL_SETTINGS"); then
    SETTINGS_ERROR="unreadable-json:$GLOBAL_SETTINGS"
    return 1
  fi
  if ! PROJECT_JSON=$(read_json_file "$PROJECT_SETTINGS_PATH"); then
    SETTINGS_ERROR="unreadable-json:$PROJECT_SETTINGS_PATH"
    return 1
  fi
  return 0
}

# resolve_settings_model <cwd> -> MODEL_PROVIDER MODEL_ID MODEL_SOURCE
# The project file wins when it names a model; otherwise the global file does.
# The provider falls back independently, exactly as pi merges the two objects.
resolve_settings_model() {
  local cwd=$1
  MODEL_PROVIDER=$(printf '%s' "$PROJECT_JSON" | jq -r '.defaultProvider // empty')
  MODEL_ID=$(printf '%s' "$PROJECT_JSON" | jq -r '.defaultModel // empty')
  if [ -n "$MODEL_ID" ]; then
    MODEL_SOURCE="$cwd/$CONFIG_DIR_NAME/settings.json"
  else
    MODEL_ID=$(printf '%s' "$GLOBAL_JSON" | jq -r '.defaultModel // empty')
    MODEL_SOURCE="$GLOBAL_SETTINGS"
  fi
  [ -n "$MODEL_PROVIDER" ] || MODEL_PROVIDER=$(printf '%s' "$GLOBAL_JSON" | jq -r '.defaultProvider // empty')
}

# effective_reserve -> RESERVE RESERVE_SOURCE RESERVE_ERROR
# Effective reserveTokens for the cwd whose settings are loaded: the project
# value when that file sets it, else the global value, else pi's built-in default.
effective_reserve() {
  local has_project has_global value
  RESERVE=
  RESERVE_SOURCE=
  RESERVE_ERROR=
  has_project=$(printf '%s' "$PROJECT_JSON" | jq -r \
    'if (.compaction? | type) == "object" then (.compaction | has("reserveTokens")) else false end')
  has_global=$(printf '%s' "$GLOBAL_JSON" | jq -r \
    'if (.compaction? | type) == "object" then (.compaction | has("reserveTokens")) else false end')
  if [ "$has_project" = true ]; then
    value=$(printf '%s' "$PROJECT_JSON" | jq -r '.compaction.reserveTokens')
    RESERVE_SOURCE=$PROJECT_SETTINGS_PATH
  elif [ "$has_global" = true ]; then
    value=$(printf '%s' "$GLOBAL_JSON" | jq -r '.compaction.reserveTokens')
    RESERVE_SOURCE=$GLOBAL_SETTINGS
  else
    value=$PI_DEFAULT_RESERVE_TOKENS
    RESERVE_SOURCE=builtin-pi-default
  fi
  case "$value" in
    ''|*[!0-9]*)
      RESERVE_ERROR="reserveTokens-is-not-a-non-negative-integer"
      return 1
      ;;
  esac
  RESERVE=$value
  return 0
}

# trigger_percent <window-tokens> <reserve-tokens>
trigger_percent() {
  awk -v w="$1" -v r="$2" 'BEGIN { printf "%.1f", (w - r) / w * 100 }'
}

# --- one session scope ------------------------------------------------------

# check_scope <name> <cwd> <provider> <model> <model-source>
# Requires the settings pair for the scope's cwd to be loaded already.
check_scope() {
  local name=$1 cwd=$2 provider=$3 model=$4 model_source=$5
  local model_display percent verdict reason
  if [ -z "$model" ]; then
    print_line error "$name" "$cwd" - - - "$model_source" no-model-configured
    return 0
  fi
  if [ -n "$provider" ]; then
    model_display="$provider/$model"
  else
    model_display="$model"
  fi
  if ! resolve_window "$provider" "$model"; then
    print_line error "$name" "$cwd" "$model_display" - - "$model_source" "$WINDOW_ERROR"
    return 0
  fi
  if ! effective_reserve; then
    print_line error "$name" "$cwd" "$model_display" "$WINDOW_DISPLAY" - \
      "$RESERVE_SOURCE" "$RESERVE_ERROR"
    return 0
  fi
  percent=$(trigger_percent "$WINDOW_TOKENS" "$RESERVE")
  verdict=ok
  reason=
  if [ "$RESERVE" -ge "$WINDOW_TOKENS" ]; then
    verdict=unsafe
    reason="reserve-not-below-window"
  elif awk -v p="$percent" -v m="$MAX_TRIGGER_PERCENT" 'BEGIN { exit !(p > m) }'; then
    verdict=unsafe
    reason=trigger-above-limit
  fi
  print_line "$verdict" "$name" "$cwd" "$model_display" "$WINDOW_DISPLAY" "$RESERVE" \
    "$RESERVE_SOURCE" "$reason" "trigger=$percent% limit=$MAX_TRIGGER_PERCENT%"
}

# check_settings_scope <name> <cwd>: model and reserve both from settings.json.
check_settings_scope() {
  local name=$1 cwd=$2
  if ! load_settings_pair "$cwd"; then
    print_line error "$name" "$cwd" - - - - "$SETTINGS_ERROR"
    return 0
  fi
  resolve_settings_model "$cwd"
  check_scope "$name" "$cwd" "$MODEL_PROVIDER" "$MODEL_ID" "$MODEL_SOURCE"
}

# check_global_scope: the pairing a cwd with no project settings receives.
check_global_scope() {
  local global_provider global_model
  PROJECT_JSON='{}'
  PROJECT_SETTINGS_PATH=
  if ! GLOBAL_JSON=$(read_json_file "$GLOBAL_SETTINGS"); then
    print_line error global-scope - - - - - "$GLOBAL_SETTINGS" unreadable-json
    return 0
  fi
  global_provider=$(printf '%s' "$GLOBAL_JSON" | jq -r '.defaultProvider // empty')
  global_model=$(printf '%s' "$GLOBAL_JSON" | jq -r '.defaultModel // empty')
  check_scope global-scope - "$global_provider" "$global_model" "$GLOBAL_SETTINGS"
}

# check_secondmate <id> <home>: model from the shared harness pin.
check_secondmate() {
  local id=$1 home=$2 line harness sm_model sm_provider
  if [ -z "$home" ] || [ ! -d "$home" ]; then
    print_line error "secondmate-$id" "${home:--}" - - - - registry-home-missing
    return 0
  fi
  if ! load_settings_pair "$home"; then
    print_line error "secondmate-$id" "$home" - - - - "$SETTINGS_ERROR"
    return 0
  fi
  line=
  if [ -f "$HARNESS_FILE" ]; then
    line=$(awk 'NF && $1 !~ /^#/ { print; exit }' "$HARNESS_FILE")
  fi
  harness=
  sm_model=
  if [ -n "$line" ]; then
    read -r harness sm_model _rest <<<"$line" || true
  fi
  if [ -n "$line" ] && [ "$harness" != pi ]; then
    print_line skipped "secondmate-$id" "$home" - - - "$HARNESS_FILE" harness-not-pi \
      "harness: $harness"
    return 0
  fi
  if [ -n "$sm_model" ]; then
    # config/secondmate-harness names a bare model id, and firstmate passes it to
    # the launch as --model; the provider follows the home's merged settings.
    sm_provider=$(printf '%s' "$PROJECT_JSON" | jq -r '.defaultProvider // empty')
    [ -n "$sm_provider" ] || sm_provider=$(printf '%s' "$GLOBAL_JSON" | jq -r '.defaultProvider // empty')
    check_scope "secondmate-$id" "$home" "$sm_provider" "$sm_model" "$HARNESS_FILE"
    return 0
  fi
  resolve_settings_model "$home"
  check_scope "secondmate-$id" "$home" "$MODEL_PROVIDER" "$MODEL_ID" "$MODEL_SOURCE"
}

# --- run --------------------------------------------------------------------

MODELS_RC=0
load_model_table || MODELS_RC=$?
if [ "$MODELS_RC" -eq 2 ]; then
  print_line skipped all - - - - "${MODELS_CMD%% *}" "$MODELS_NOT_APPLICABLE"
  exit 0
fi
if [ "$MODELS_RC" -ne 0 ]; then
  print_line error all - - - - "$MODELS_CMD" "$MODELS_ERROR"
  exit 2
fi

if [ -d "$PRIMARY_HOME" ]; then
  check_settings_scope primary "$PRIMARY_HOME"
else
  print_line error primary "$PRIMARY_HOME" - - - - primary-home-missing
fi

check_global_scope

if [ -f "$SECONDMATES_FILE" ]; then
  while IFS='|' read -r sm_id sm_home; do
    [ -n "$sm_id" ] || continue
    check_secondmate "$sm_id" "$sm_home"
  done < <(awk '
    /^- / {
      id = $2
      if (match($0, /\(home: [^;)]+/)) {
        home = substr($0, RSTART + 7, RLENGTH - 7)
        gsub(/^[ \t]+|[ \t]+$/, "", home)
        printf "%s|%s\n", id, home
      }
    }
  ' "$SECONDMATES_FILE")
fi

exit "$VERDICT_WORST"
