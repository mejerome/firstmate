#!/usr/bin/env bash
# Install the host tools the CI suite names but a bare runner image can lack.
#
# .github/workflows/ci.yml runs this once per job that executes repo tooling.
# It is a no-op when every tool already resolves on PATH, so a GitHub-hosted
# image pays nothing, and one bounded package transaction fills the gap on a
# forge whose runner image ships fewer tools. The default list is the inventory
# the suite itself names, each with its owner:
#   curl     - the pinned installers for ShellCheck, actionlint, Herdr, Treehouse
#   jq       - the suite's JSON assertions and the Herdr/zellij adapters
#   perl     - fm-lint.sh's mandatory bounded-worker watchdog
#   python3  - fm-test-run.sh timing aggregation and the Herdr lab viewer
#   ruby     - tests/fm-ci-workflow.test.sh and the no-mistakes contract test
#   tmux     - the real AFK injection e2e coverage
#   tsc      - the Pi extension typecheck the lanes refuse to gate-skip around
#              (installed from npm, the only source that provides it)
#
# Extra arguments are extra package names, so a future job can extend the set
# without a second installer.
# Usage: fm-ci-prerequisites.sh [extra-package...]
#
# Exit status is 0 when every default tool resolves on PATH afterwards, and 1
# with the missing tool named when the runner cannot supply it; a job that needs
# the tool then fails loudly instead of losing coverage silently.
set -eu

DEFAULT_TOOLS='curl jq perl python3 ruby tmux'
DEFAULT_NPM_TOOLS='tsc'

missing=
for tool in $DEFAULT_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
missing_npm=
for tool in $DEFAULT_NPM_TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || missing_npm="$missing_npm $tool"
done
packages="${missing# }"
for extra in "$@"; do
  packages="$packages $extra"
done
packages="${packages# }"

if [ -z "$packages" ] && [ -z "$missing_npm" ]; then
  printf 'fm-ci-prerequisites: all of %s %s already resolve on PATH\n' \
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
exit "$status"
