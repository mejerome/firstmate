#!/usr/bin/env bash
# Install the host tools the CI suite names but a bare runner image can lack.
#
# .github/workflows/ci.yml runs this once per job that executes repo tooling.
# It is a no-op when every tool already resolves on PATH at a usable version, so
# a GitHub-hosted image pays nothing, and one bounded package transaction fills
# the gap on a forge whose runner image ships fewer or older tools. The default
# set is the inventory the suite itself names, each with its owner:
#   curl          - the pinned installers for ShellCheck, actionlint, Herdr, jq
#   jq            - the suite's JSON assertions and the Herdr/zellij adapters;
#                   gated on version 1.7+, because jq 1.6 reserves `label` and
#                   the suite's `$label` programs do not compile there
#   perl          - fm-lint.sh's mandatory bounded-worker watchdog
#   python3       - fm-test-run.sh timing aggregation and the Herdr lab viewer
#   ruby          - tests/fm-ci-workflow.test.sh and the no-mistakes contract test
#   tmux          - the real AFK injection e2e coverage
#   tsc           - the Pi extension typecheck the lanes refuse to gate-skip around
#                   (installed from npm, the only source that provides it)
#   /usr/bin/time - fm-lint.sh's per-root RSS reporting; probed by absolute path
#                   because `time` is also a shell builtin
#
# Extra arguments are extra package names, so a future job can extend the set
# without a second installer.
# Usage: fm-ci-prerequisites.sh [extra-package...]
#
# Exit status is 0 when every default tool resolves afterwards, and 1 with the
# missing tool named when the runner cannot supply it; a job that needs the tool
# then fails loudly instead of losing coverage silently.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEFAULT_TOOLS='curl perl python3 ruby tmux'
DEFAULT_NPM_TOOLS='tsc'
# GNU time is probed by absolute path: `time` is also a shell builtin, so a
# command lookup would pass while /usr/bin/time is absent and the suite's
# per-root RSS reporting stays unavailable.
DEFAULT_PATH_TOOLS='/usr/bin/time'
# jq is probed by version, not by presence: a distribution jq 1.6 is present and
# unusable, so "found" is not "usable" and a silent downgrade would red the
# contribution lanes for a runner-image reason.
JQ_MIN_MAJOR=1
JQ_MIN_MINOR=7

jq_usable() {
  local version major minor
  version=$(jq --version 2>/dev/null) || return 1
  version=${version#jq-}
  major=${version%%.*}
  minor=${version#*.}
  minor=${minor%%.*}
  case "${major}${minor}" in '' | *[!0-9]*) return 1 ;; esac
  [ "$major" -gt "$JQ_MIN_MAJOR" ] ||
    { [ "$major" -eq "$JQ_MIN_MAJOR" ] && [ "$minor" -ge "$JQ_MIN_MINOR" ]; }
}

missing=
for tool in $DEFAULT_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
for path in $DEFAULT_PATH_TOOLS; do
  [ -x "$path" ] || missing="$missing ${path##*/}"
done
missing_npm=
for tool in $DEFAULT_NPM_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || missing_npm="$missing_npm $tool"
done
need_jq=0
jq_usable || need_jq=1
packages="${missing# }"
for extra in "$@"; do
  packages="$packages $extra"
done
packages="${packages# }"

if [ -z "$packages" ] && [ -z "$missing_npm" ] && [ "$need_jq" -eq 0 ]; then
  printf 'fm-ci-prerequisites: %s %s jq already resolve on PATH at usable versions\n' \
    "$DEFAULT_TOOLS" "$DEFAULT_NPM_TOOLS"
  exit 0
fi

if [ -n "$packages" ]; then
  printf 'fm-ci-prerequisites: installing %s\n' "$packages"

  if ! command -v apt-get >/dev/null 2>&1; then
    printf 'fm-ci-prerequisites: no apt-get on this runner, cannot install:%s\n' "$packages" >&2
    exit 1
  fi
  if [ "$(id -u)" -ne 0 ]; then
    printf 'fm-ci-prerequisites: must run as root to install:%s\n' "$packages" >&2
    exit 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # Word splitting is the point: packages is a space-separated name list.
  # shellcheck disable=SC2086
  apt-get install -y -qq --no-install-recommends $packages
fi

if [ "$need_jq" -eq 1 ]; then
  # One pinned build on both forges, installed ahead of any distribution jq so
  # the rest of this job and every later step compile the suite's programs.
  jq_destination="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-ci-bin"
  "$ROOT/bin/fm-install-jq.sh" "$jq_destination"
  PATH="$jq_destination:$PATH"
  export PATH
  if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$jq_destination" >> "$GITHUB_PATH"
  fi
fi

# tsc comes from npm on every image this workflow meets, and only npm ships it.
case " $missing_npm " in
  *' tsc '*)
    if ! command -v npm >/dev/null 2>&1; then
      printf 'fm-ci-prerequisites: npm is required to install:%s\n' "$missing_npm" >&2
      exit 1
    fi
    printf 'fm-ci-prerequisites: installing %s from npm\n' "$missing_npm"
    npm install -g typescript
    ;;
esac

status=0
for tool in $DEFAULT_TOOLS $DEFAULT_NPM_TOOLS; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf 'fm-ci-prerequisites: %s -> %s\n' "$tool" "$(command -v "$tool")"
  else
    printf 'fm-ci-prerequisites: %s is still missing after install\n' "$tool" >&2
    status=1
  fi
done
for path in $DEFAULT_PATH_TOOLS; do
  if [ -x "$path" ]; then
    printf 'fm-ci-prerequisites: %s -> %s\n' "${path##*/}" "$path"
  else
    printf 'fm-ci-prerequisites: %s is still missing after install\n' "$path" >&2
    status=1
  fi
done
if jq_usable; then
  printf 'fm-ci-prerequisites: jq -> %s (%s)\n' "$(command -v jq)" "$(jq --version 2>/dev/null)"
else
  printf 'fm-ci-prerequisites: jq is missing or older than %s.%s after install\n' \
    "$JQ_MIN_MAJOR" "$JQ_MIN_MINOR" >&2
  status=1
fi
exit "$status"
