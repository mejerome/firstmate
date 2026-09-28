#!/usr/bin/env bash
# Tests for bin/fm-zulip-dm.sh - the captain-facing message carrier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-zulip-dm.sh"
TMP_ROOT=$(fm_test_tmproot fm-zulip-dm)

# --- helper: create a message file for testing ---
create_message_file() {
    local dir=$1 label=$2
    printf '%s\n' "Test DM: $label" > "$dir/message.txt"
    printf '%s\n' "$dir/message.txt"
}

# --- failure path: missing credential file ---
test_missing_credential_file() {
    local case_dir
    case_dir="$TMP_ROOT/missing-file"
    mkdir -p "$case_dir"

    local msg_file
    msg_file=$(create_message_file "$case_dir" "missing-cred-file")

    # Temporarily move the real credential file away
    local real_cred="/root/.pi/agent/extensions/zulip/.env"
    local rc=0
    local output
    if [ -f "$real_cred" ]; then
        mv "$real_cred" "$case_dir/.env.real"
        output=$(bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?
        mv "$case_dir/.env.real" "$real_cred"
    else
        output=$(bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?
    fi

    expect_code 1 "$rc" "missing credential file must exit 1"
    assert_contains "$output" "missing credential file" "error message must name the missing file"
    assert_contains "$output" "/root/.pi/agent/extensions/zulip/.env" "error message must contain the credential file path"
    pass "script fails loudly when credential file is absent"
}

# --- failure path: missing credential variable ---
test_missing_credential_variable() {
    local case_dir
    case_dir="$TMP_ROOT/missing-var"
    mkdir -p "$case_dir"

    local msg_file
    msg_file=$(create_message_file "$case_dir" "missing-var")

    # Create a credential file without the required variable
    local tmp_env="$case_dir/.env"
    printf '# comment\nOTHER_VAR=something\n' > "$tmp_env"

    # Temporarily replace the credential file
    local real_cred="/root/.pi/agent/extensions/zulip/.env"
    if [ -f "$real_cred" ]; then
        mv "$real_cred" "$case_dir/.env.real"
        cp "$tmp_env" "$real_cred"
        local rc=0
        local output
        output=$(bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?
        mv "$case_dir/.env.real" "$real_cred"
    else
        local rc=0
        local output
        output=$(bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?
    fi

    expect_code 1 "$rc" "missing credential variable must exit 1"
    assert_contains "$output" "missing credential variable ABIBA_ZULIP_API_KEY" "error message must name the missing variable"
    pass "script fails loudly when credential variable is absent"
}

# --- failure path: empty credential variable ---
test_empty_credential_variable() {
    local case_dir
    case_dir="$TMP_ROOT/empty-var"
    mkdir -p "$case_dir"

    local msg_file
    msg_file=$(create_message_file "$case_dir" "empty-var")

    # Create a credential file with an empty variable
    local tmp_env="$case_dir/.env"
    printf '# comment\nABIBA_ZULIP_API_KEY=\n' > "$tmp_env"

    # Temporarily replace the credential file
    local real_cred="/root/.pi/agent/extensions/zulip/.env"
    if [ -f "$real_cred" ]; then
        mv "$real_cred" "$case_dir/.env.real"
        cp "$tmp_env" "$real_cred"
        local rc=0
        local output
        output=$(bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?
        mv "$case_dir/.env.real" "$real_cred"
    else
        local rc=0
        local output
        output=$(bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?
    fi

    expect_code 1 "$rc" "empty credential variable must exit 1"
    assert_contains "$output" "credential variable ABIBA_ZULIP_API_KEY is empty" "error message must indicate the variable is empty"
    pass "script fails loudly when credential variable is empty"
}

# --- failure path: invalid API response (no message id) ---
test_invalid_api_response() {
    local case_dir
    case_dir="$TMP_ROOT/invalid-response"
    mkdir -p "$case_dir"

    local msg_file
    msg_file=$(create_message_file "$case_dir" "invalid-response")

    # Create a fake curl that returns invalid JSON
    local fakecurl="$case_dir/curl"
    cat > "$fakecurl" <<'SH'
#!/usr/bin/env bash
# Return invalid JSON that jq cannot parse
printf '%s\n' '{"broken": "json"}'
SH
    chmod +x "$fakecurl"

    # Create a fake jq that returns nothing
    local fakejq="$case_dir/jq"
    cat > "$fakejq" <<'SH'
#!/usr/bin/env bash
# Return nothing (simulating jq failure)
SH
    chmod +x "$fakejq"

    # Use PATH to select fake curl (no need to move the system binary)
    local rc=0
    local output
    output=$(PATH="$case_dir:$PATH" bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?

    expect_code 1 "$rc" "invalid API response must exit 1"
    assert_contains "$output" "failed to send message" "error message must indicate send failure"
    pass "script fails loudly when API returns invalid response"
}

# --- live send (opt-in) ---
# Use FM_ZULIP_LIVE=1 to enable this test
test_live_send() {
    if [ -z "${FM_ZULIP_LIVE:-}" ]; then
        pass "live test skipped (set FM_ZULIP_LIVE=1 to enable)"
        return 0
    fi

    local case_dir
    case_dir="$TMP_ROOT/live-send"
    mkdir -p "$case_dir"

    local msg_file
    msg_file=$(create_message_file "$case_dir" "live-test-$(date +%s)")

    local rc=0
    local message_id
    message_id=$(bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?

    expect_code 0 "$rc" "live send must succeed"
    [ -n "$message_id" ] || fail "live send message ID must be printed"
    [[ "$message_id" =~ ^[0-9]+$ ]] || fail "message ID must be numeric: $message_id"
    pass "live Zulip DM sent successfully"
}

# Run tests
test_missing_credential_file
test_missing_credential_variable
test_empty_credential_variable
test_invalid_api_response
test_live_send
