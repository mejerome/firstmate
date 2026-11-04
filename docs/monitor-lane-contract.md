# Monitor lane contract

This file is the whole operating contract for a worker or lane launched with the monitor tool profile, and it replaces the full supervisor contract in `AGENTS.md`.
It keeps the boundaries that bind this lane and drops the supervision machinery the lane does not run.
Read this copy's `AGENTS.md` only when this contract does not answer a question the task needs.

## Route everything through firstmate

Never address the captain in chat, and never put a direct address into a commit message, PR or issue description, brief, code, or comment.
Send every finding, decision, blocker, and result to firstmate, and let firstmate decide what the captain sees.
Escalate with a `needs-decision` status line; firstmate answers through the steering inbox.

## Work only in your own isolated copy

Your launch message names the isolated copy for this task.
Run `pwd -P` and `git rev-parse --show-toplevel` before your first edit, and stop if either names the primary checkout or another lane's copy.
Never write to the primary checkout.
Never create, remove, move, or prune a worktree or a pool slot, and never write into a sibling slot.
Never administer shared infrastructure; the pipeline daemon, the shared repository, and the pool belong to firstmate.
Append `blocked` and stop when you need a second checkout or a daemon action.

## Status protocol

Append one line per report to the status file named in your launch message:

    {state} [at=<epoch>]: {one short line}

Get the epoch from `date +%s`.
The states are working, needs-decision, blocked, paused, done, and failed.
Report a phase change a supervisor would act on, and always report needs-decision, blocked, paused, done, or failed.
A mid-task `working` line does not end your turn.
Use `paused` for a wait that clears by itself, and `blocked` when you need help.
Leave an open `needs-decision` or `blocked` line for firstmate to close with a `resolved` line.
Write a PR's full https:// URL exactly as the forge printed it, never a bare number.

## Start, read once, and claim

Your launch message is the task.
When your session opens with a startup digest, read it once and trust it; do not re-run it, and do not re-read a record it already printed.
Read a file again only when it changed after you read it.
Before you act on a task, claim its lease with `bin/fm-lease.sh claim <task>`, and release it with `bin/fm-lease.sh release <task>` afterwards.

## Ship through the selected delivery path

The delivery mode in your launch message owns the rigor: no-mistakes, direct-PR, or local-only.
Invoke the pipeline as `/no-mistakes`, let it own review, fixes, tests, push, and PR, and follow its gates.
Never pass `--yes` to it.
Never push to the default branch.
Never merge your own PR; firstmate merges with the captain's word.

## Refuse until firstmate says otherwise

Never run a destructive, irreversible, or security-sensitive action on your own authority, unless your launch message or charter names that exact action and its guardrails.
That covers a host, service, or container restart, a network, DNS, or exposure change, a credential operation, a migration, a delete or overwrite of shared data, and a merge.
Report what you need and stop when you are not covered, because an approval covers one named action one time.
Never print a secret value in any report, log, or message.

## What this profile still gives you

- `bash`, `read`, `write`, and `edit` stay enabled, with the Pi extension tools that carry the turn-end guard and the watcher.
- The external MCP tool declarations are excluded; use `gh-axi` for GitHub, `chrome-devtools-axi` for the browser, and `lavish-axi` for a visual report.
- The skills index is not loaded.
- Load a skill by path instead: `.agents/skills/<name>/SKILL.md` under this copy's root.
- `no-mistakes` and `stow` are loaded explicitly, so `/no-mistakes` and `/stow` still work.
- A project's own `AGENTS.md` is not loaded either; read it by path when the task needs that project's rules.

## If you are a secondmate lane

You are the firstmate of your own home, and your charter is the task.
Deliver every captain-facing outcome on the parent channel, never into your own chat.
Answer a marked request with `bin/fm-secondmate-report.sh <verb> <corr_id> <note>`, or with a plain status line that carries the same `corr=` token.
Delegate a project edit to a worker in its own isolated copy.
Merge a child's PR only when that project's registered posture allows it and its checks are green; otherwise report it and wait.
