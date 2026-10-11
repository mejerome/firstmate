#!/usr/bin/env bash
# Tests for bin/fm-zulip-dm.sh - the captain-facing message carrier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The script under test. FM_ZULIP_DM_SCRIPT exists so this suite can prove it
# bites: pointing it at a silent no-op (e.g. /bin/true) must make the failure
# assertions below fail, which is the exact defect the helper exists to prevent.
SCRIPT="${FM_ZULIP_DM_SCRIPT:-$ROOT/bin/fm-zulip-dm.sh}"
TMP_ROOT=$(fm_test_tmproot fm-zulip-dm)

# Defence in depth: these failure cases point FM_ZULIP_CREDENTIAL_FILE at temp
# files so nothing real on the host is moved or replaced. The trap is a safety
# net only; in the normal path it should have nothing to restore.
cleanup_zulip_dm() {
    rm -rf "$TMP_ROOT"
}
trap cleanup_zulip_dm EXIT

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

    # Point the credential file at a path that does not exist (nothing real moved)
    local fake_cred="$case_dir/absent.env"
    local rc=0
    local output
    output=$(FM_ZULIP_CREDENTIAL_FILE="$fake_cred" bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?

    expect_code 1 "$rc" "missing credential file must exit 1"
    assert_contains "$output" "missing credential file" "error message must name the missing file"
    assert_contains "$output" "$fake_cred" "error message must contain the credential file path"
    pass "script fails loudly when credential file is absent"
}

# --- failure path: missing credential variable ---
test_missing_credential_variable() {
    local case_dir
    case_dir="$TMP_ROOT/missing-var"
    mkdir -p "$case_dir"

    local msg_file
    msg_file=$(create_message_file "$case_dir" "missing-var")

    # Create a credential file without the required variable (nothing real moved)
    local tmp_env="$case_dir/.env"
    printf '# comment\nOTHER_VAR=something\n' > "$tmp_env"

    local rc=0
    local output
    output=$(FM_ZULIP_CREDENTIAL_FILE="$tmp_env" bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?

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

    # Create a credential file with an empty variable (nothing real moved)
    local tmp_env="$case_dir/.env"
    printf '# comment\nABIBA_ZULIP_API_KEY=\n' > "$tmp_env"

    local rc=0
    local output
    output=$(FM_ZULIP_CREDENTIAL_FILE="$tmp_env" bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?

    expect_code 1 "$rc" "empty credential variable must exit 1"
    assert_contains "$output" "credential variable ABIBA_ZULIP_API_KEY is empty" "error message must indicate the variable is empty"
    pass "script fails loudly when credential variable is empty"
}

# --- failure path: API refuses the send (Zulip error JSON) ---
# Uses the real jq so this exercises the helper's actual response handling: a
# Zulip refusal carries no top-level "id", so the helper must exit non-zero and
# surface the API's own reason.
test_api_error_response() {
    local case_dir
    case_dir="$TMP_ROOT/api-error"
    mkdir -p "$case_dir"

    local msg_file
    msg_file=$(create_message_file "$case_dir" "api-error")

    local fakecurl="$case_dir/curl"
    cat > "$fakecurl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"result":"error","code":"INVALID_API_KEY","msg":"Invalid API key"}'
SH
    chmod +x "$fakecurl"

    local fakecred="$case_dir/cred.env"
    printf '%s\n' 'ABIBA_ZULIP_API_KEY=test-key' > "$fakecred"

    local rc=0
    local output
    output=$(PATH="$case_dir:$PATH" FM_ZULIP_CREDENTIAL_FILE="$fakecred" bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?

    expect_code 1 "$rc" "API refusal must exit 1"
    assert_contains "$output" "failed to send message" "error message must indicate send failure"
    assert_contains "$output" "Invalid API key" "error message must surface the API's own reason"
    pass "script fails loudly when the API refuses the send"
}

# --- failure path: curl cannot reach the API ---
test_curl_failure() {
    local case_dir
    case_dir="$TMP_ROOT/curl-failure"
    mkdir -p "$case_dir"

    local msg_file
    msg_file=$(create_message_file "$case_dir" "curl-failure")

    local fakecurl="$case_dir/curl"
    cat > "$fakecurl" <<'SH'
#!/usr/bin/env bash
exit 7
SH
    chmod +x "$fakecurl"

    local fakecred="$case_dir/cred.env"
    printf '%s\n' 'ABIBA_ZULIP_API_KEY=test-key' > "$fakecred"

    local rc=0
    local output
    output=$(PATH="$case_dir:$PATH" FM_ZULIP_CREDENTIAL_FILE="$fakecred" bash "$SCRIPT" "$msg_file" 2>&1) || rc=$?

    expect_code 1 "$rc" "curl failure must exit 1"
    assert_contains "$output" "curl failed to reach Zulip API" "error message must state the network failure"
    pass "script fails loudly when curl cannot reach the API"
}

# --- failure path: non-numeric recipient ---
test_invalid_to() {
    local case_dir
    case_dir="$TMP_ROOT/bad-to"
    mkdir -p "$case_dir"

    local msg_file
    msg_file=$(create_message_file "$case_dir" "bad-to")

    local fakecred="$case_dir/cred.env"
    printf '%s\n' 'ABIBA_ZULIP_API_KEY=test-key' > "$fakecred"

    local rc=0
    local output
    output=$(FM_ZULIP_CREDENTIAL_FILE="$fakecred" bash "$SCRIPT" "$msg_file" --to mumuni-bot 2>&1) || rc=$?

    expect_code 1 "$rc" "non-numeric --to must exit 1"
    assert_contains "$output" "invalid --to user id" "error message must explain the bad recipient"
    pass "script fails loudly on a non-numeric recipient"
}

# --- success path: a body from stdin survives untouched ---
# Uses a fake curl that records the body file the helper hands it, so this
# proves both that stdin is accepted and that shell metacharacters survive.
test_stdin_body() {
    local case_dir
    case_dir="$TMP_ROOT/stdin-body"
    mkdir -p "$case_dir"

    local fakecurl="$case_dir/curl"
    cat > "$fakecurl" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    case "$1" in
        content@*) cat "${1#content@}" >"$FM_TEST_CAPTURE" ;;
    esac
    shift
done
printf '%s\n' '{"id": 424242}'
SH
    chmod +x "$fakecurl"

    local fakecred="$case_dir/cred.env"
    printf '%s\n' 'ABIBA_ZULIP_API_KEY=test-key' > "$fakecred"

    local rc=0
    local output
    # shellcheck disable=SC2016 # the shell metacharacters are literal body text, not to expand here
    output=$(printf 'line one\nline two "$(danger)" `x`\n' \
        | PATH="$case_dir:$PATH" FM_TEST_CAPTURE="$case_dir/captured" \
          FM_ZULIP_CREDENTIAL_FILE="$fakecred" bash "$SCRIPT" - 2>&1) || rc=$?

    expect_code 0 "$rc" "stdin body must send successfully"
    assert_contains "$output" "424242" "message id must be printed"
    [ -f "$case_dir/captured" ] || fail "fake curl did not capture the body"
    # shellcheck disable=SC2016 # asserts the same literal body text
    assert_contains "$(cat "$case_dir/captured")" 'line two "$(danger)" `x`' "body characters must survive untouched"
    pass "stdin body survives untouched and the message id is printed"
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
test_invalid_to
test_api_error_response
test_curl_failure
test_stdin_body
test_live_send
