#!/usr/bin/env bash
# fm-zulip-dm.sh - Send a private Zulip DM from the captain-facing message
# carrier bot to the captain or a specific agent bot.
#
# Usage: fm-zulip-dm.sh <message-file> [--to <user-id>]
#
# The message body is read from a file (required) so large multi-line Markdown
# and any characters survive untouched. Use '-' for stdin.
#
# Credential: ABIBA_ZULIP_API_KEY from /root/.pi/agent/extensions/zulip/.env
# (mode 600, shell-sourceable format). Never printed.
#
# Exit 0 on success (prints Zulip message id). Exit non-zero on any failure.

set -euo pipefail

# --- Credential ---
# Override the credential file location via FM_ZULIP_CREDENTIAL_FILE (used by tests
# to point at a temp file so no real host file is ever moved or replaced).
ZULIP_CREDENTIAL_FILE="${FM_ZULIP_CREDENTIAL_FILE:-/root/.pi/agent/extensions/zulip/.env}"
ZULIP_CREDENTIAL_VAR="ABIBA_ZULIP_API_KEY"

# Default bot identity
ZULIP_BOT="abiba-bot@chat.sysloggh.net"

# Default Zulip API endpoint
ZULIP_API_URL="https://chat.sysloggh.net/api/v1/messages"

# Default recipient (captain)
DEFAULT_TO="[9]"

# --- Helpers ---
die() {
    printf "ERROR: %s\n" "$*" >&2
    exit 1
}

# --- Argument parsing ---
MESSAGE_FILE=""
RECIPIENT="$DEFAULT_TO"

while [ $# -gt 0 ]; do
    case "$1" in
        --to)
            if [ -z "${2:-}" ]; then
                die "missing value for --to"
            fi
            RECIPIENT="[$2]"
            shift 2
            ;;
        *)
            if [ -z "$MESSAGE_FILE" ]; then
                MESSAGE_FILE="$1"
                shift
            else
                die "unexpected argument: $1"
            fi
            ;;
    esac
done

if [ -z "$MESSAGE_FILE" ]; then
    die "usage: fm-zulip-dm.sh <message-file> [--to <user-id>]"
fi

# --- Validate credential ---
if [ ! -f "$ZULIP_CREDENTIAL_FILE" ]; then
    die "missing credential file: $ZULIP_CREDENTIAL_FILE"
fi

if ! grep -q "^${ZULIP_CREDENTIAL_VAR}=" "$ZULIP_CREDENTIAL_FILE" 2>/dev/null; then
    die "missing credential variable $ZULIP_CREDENTIAL_VAR in $ZULIP_CREDENTIAL_FILE"
fi

# Read the key (no quotes, no trailing newline)
API_KEY=$(grep "^${ZULIP_CREDENTIAL_VAR}=" "$ZULIP_CREDENTIAL_FILE" | sed "s/^${ZULIP_CREDENTIAL_VAR}=//" | tr -d '\n')

if [ -z "$API_KEY" ]; then
    die "credential variable $ZULIP_CREDENTIAL_VAR is empty"
fi

# --- Validate message file ---
if [ "$MESSAGE_FILE" = "-" ]; then
    # Read stdin to a temp file
    TMP_FILE=$(mktemp)
    trap 'rm -f "$TMP_FILE"' EXIT
    cat > "$TMP_FILE"
    MESSAGE_FILE="$TMP_FILE"
else
    if [ ! -f "$MESSAGE_FILE" ]; then
        die "message file not found: $MESSAGE_FILE"
    fi
fi

# --- Send message ---
RESPONSE=$(curl -s -u "${ZULIP_BOT}:${API_KEY}" \
    -X POST "$ZULIP_API_URL" \
    --data-urlencode "type=private" \
    --data-urlencode "to=${RECIPIENT}" \
    --data-urlencode "content@${MESSAGE_FILE}")

# Extract message id from response
MESSAGE_ID=$(printf "%s" "$RESPONSE" | jq -r '.id // empty' 2>/dev/null)

if [ -z "$MESSAGE_ID" ]; then
    die "failed to send message: API returned unexpected response: $RESPONSE"
fi

printf "%s\n" "$MESSAGE_ID"
