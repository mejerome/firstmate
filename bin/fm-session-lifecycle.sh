#!/usr/bin/env bash
# fm-session-lifecycle.sh — enforce the superagent session registry lifecycle
#
# Additive: does not modify any existing script. It wraps the existing
# session-registry.sh (in prose-contracts/scripts/) and runs:
#   1. cleanup  — apply the lifecycle policy to the live registry
#   2. sync     — produce a committed snapshot (not the authority)
#
# Lifecycle rules (from session-registry.sh):
#   active          — never deleted
#   done            — deleted after 24h grace period
#   stale           — deleted after 7h of no activity
#   in_conversation — never deleted
#
# Usage:
#   fm-session-lifecycle.sh [--dry-run]
#
# The live authority stays at /rah-os/data/sessions.jsonl.
# The committed snapshot is a record, not the authority.
set -euo pipefail

WORKSPACE="/root/abiba-workspace"
SCRIPTS="$WORKSPACE/projects/prose-contracts/scripts"
SESSION_REGISTRY_SH="$SCRIPTS/session-registry.sh"
REGISTRY="${SESSION_REGISTRY:-/rah-os/data/sessions.jsonl}"
SNAPSHOT="$WORKSPACE/projects/prose-contracts/data/sessions.jsonl"
DRY_RUN=0

if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
fi

if [ ! -x "$SESSION_REGISTRY_SH" ]; then
  echo "fm-session-lifecycle: $SESSION_REGISTRY_SH not found or not executable" >&2
  exit 1
fi

echo "fm-session-lifecycle: $([ "$DRY_RUN" = 1 ] && echo "DRY-RUN" || echo "LIVE")"
echo "  registry: $REGISTRY"
echo "  snapshot: $SNAPSHOT"

# Step 1: cleanup (apply lifecycle policy to the live registry)
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] would run: session-registry.sh cleanup"
else
  SESSION_REGISTRY="$REGISTRY" "$SESSION_REGISTRY_SH" cleanup
fi

# Step 2: sync (produce the committed snapshot)
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] would run: session-registry.sh sync"
else
  SESSION_REGISTRY="$REGISTRY" "$SESSION_REGISTRY_SH" sync
fi

# Step 3: verify (check the snapshot)
"$SESSION_REGISTRY_SH" check 2>/dev/null || echo "  [warn] snapshot check failed"

echo "fm-session-lifecycle: done"
