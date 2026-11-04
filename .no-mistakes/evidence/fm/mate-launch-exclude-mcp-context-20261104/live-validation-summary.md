# Live Validation Summary: fm/mate-launch-exclude-mcp-context-20261104

## Change Overview
Two features:
1. `--tool-profile <monitor|incident>` in `bin/fm-spawn.sh` - reduced tool surface for monitoring agents
2. Secondmate checkpoint in `bin/fm-session-start.sh` - bounded session-start digest for worker homes

## Test Results
### fm-spawn-tool-profile.test.sh (6 cases, all pass)
- **monitor profile on pi**: Launch includes `--exclude-tools github-*,context7-*,firecrawl-*,searxng-*,ra-h-os-*`, keeps `-e` extensions, records `tool_profile=monitor`
- **default profile**: No exclusion flags, records `tool_profile=incident`
- **incident profile**: Same as default, no `--exclude-tools`
- **unknown profile**: Refused by name before any record/launch
- **inexpressible harness**: `--harness claude --tool-profile monitor` refused
- **relaunch profile override**: `--relaunch --tool-profile monitor` refused

### fm-session-start-secondmate-checkpoint.test.sh (3 cases, all pass)
- **secondmate checkpoint**: Bounded digest, keeps lock/wake queue, drops task record bodies
- **primary unchanged**: Full digest printed as before
- **full digest escape**: `FM_SESSION_START_FULL_DIGEST=1` works

## Live Validation
- `pi --exclude-tools 'github-*,context7-*,firecrawl-*,searxng-*,ra-h-os-*' --help` exits 0 (flag accepted)
- Session-start checkpoint mode: 184 lines vs 193 lines for primary on minimal fixture
- Checkpoint correctly omits task record bodies, backlog bodies, context file bodies
- Presence facts (ABSENT, present, size) still reported
- Full-digest escape produces the full digest in a secondmate home
