#!/usr/bin/env bash
# tests/fm-secondmate-report.test.sh - a secondmate's marked from-firstmate
# answer must persist one corr-bearing line on the durable parent channel, and
# the corr token is mandatory.
#
# The failure this pins: the mate printed a done heading on its pane and used a
# key= label with no corr token, so the parent status file never received the
# outcome. This test drives the real helper against a seeded local secondmate
# home and asserts the resolved parent state/<id>.status carries corr=<id>.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPORT="$ROOT/bin/fm-secondmate-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-report)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

CORR=c44897ee2db4326b
MATE_ID=reportmate-z1
PARENT="$TMP_ROOT/parent-home"
MATE="$TMP_ROOT/mate-home"

build_seed() {
  mkdir -p "$PARENT/state" "$MATE/state" "$MATE/data"
  printf '%s\n' "$MATE_ID" > "$MATE/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" \
    > "$MATE/.fm-secondmate-parent"
}

case_marked_reply_is_appended_with_corr() {
  local status line
  build_seed
  status="$PARENT/state/$MATE_ID.status"

  FM_HOME="$MATE" "$REPORT" done "$CORR" "disk check clean" \
    || fail "the report helper failed to append a correlated reply"

  [ -f "$status" ] || fail "the resolved parent status file was not created"
  line=$(grep -F "corr=$CORR" "$status" || true)
  [ -n "$line" ] || fail "the parent status file has no corr=$CORR line"
  assert_contains "$line" 'done' \
    "the persisted reply must carry the done verb"
  assert_contains "$line" 'disk check clean' \
    "the persisted reply must carry the outcome note"
  assert_contains "$line" 'via-helper' \
    "the persisted reply must be traceable to the executed helper append"
  pass "a marked reply is appended to the durable parent status channel with its corr token"
}

case_corr_is_required_and_validated() {
  local status rc=0
  build_seed
  status="$PARENT/state/$MATE_ID.status"
  rm -f "$status"

  rc=0
  FM_HOME="$MATE" "$REPORT" done "" "no corr token" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an empty corr must be refused"

  rc=0
  FM_HOME="$MATE" "$REPORT" done 'key=disk-check' "key label without corr" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a key= label must not be accepted as a corr token"

  rc=0
  FM_HOME="$MATE" "$REPORT" done 'c44897ee2db4326' "short corr" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a non-16-hex corr must be refused"

  [ ! -e "$status" ] || fail "a refused report still wrote the parent status file"
  pass "the report helper rejects an empty, key=, or non-16-hex corr"
}

case_brief_requires_executed_corr_append() {
  local home brief
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" report-contract --secondmate --no-projects >/dev/null 2>&1 \
    || fail "could not scaffold the secondmate brief"
  brief="$home/data/report-contract/brief.md"

  assert_grep "reuse that exact \`corr=<id>\` token" "$brief" \
    "the charter did not require reuse of the steer corr token"
  assert_grep 'Execute the append as the final reporting action' "$brief" \
    "the charter did not require an executed append"
  assert_grep 'A screen echo does not count as a report' "$brief" \
    "the charter did not reject a pane-only echo as the report"
  assert_grep "a \`key=\` label without \`corr=<id>\`" "$brief" \
    "the charter did not reject a key label without the corr token"
  pass "the secondmate charter requires an executed corr-bearing parent append"
}

case_marked_reply_is_appended_with_corr
case_corr_is_required_and_validated
case_brief_requires_executed_corr_append

echo "# all fm-secondmate-report tests passed"
