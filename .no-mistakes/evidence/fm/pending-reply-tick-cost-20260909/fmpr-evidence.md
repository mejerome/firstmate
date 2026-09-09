# fm_pending_reply_tick settled-record fast path — test evidence

Change under test: `fm/pending-reply-tick-cost-20260909`
Base: `60915d9` · Target: `cb95908` (`bin/fm-pending-reply-lib.sh` + `tests/fm-pending-reply.test.sh`)

## 1. Automated regression coverage (tests/fm-pending-reply.test.sh)

Full file run on the target tree: **all 36 tests pass**, including the two new ones:

```
ok - tick fast path: settled records cost no lock, no re-read, no subprocess
ok - tick still closes an open escalation on a resolved record
```

Regression reproduction — same test file sourced against the BASE (pre-fix) library:
all 35 pre-existing tests still pass, and the new fast-path test **fails**, proving it
guards the fix:

```
not ok - a settled store must not take the per-correlation lock, close log: close
close
not ok - settled fast-path regression failed
```

The new tests exercise real library behavior (fixtures built through the public
`fm_pending_reply_create`/`mark_delivered`/`try_resolve` API):
- resolved+closed and never-escalated records perform zero `close_escalation` work on a
  tick pass, and the same store still ticks with `PATH=/nonexistent` (builtin-only, no
  subprocess);
- a resolved record with a still-open escalation IS still closed by the tick exactly
  once (escalation_closed_epoch set, decision closed once) — semantics unchanged.

## 2. Before/after measurement on the same fixture store (2283 settled records)

Fixtures: 2283 fully settled records (phase=resolved, escalated_epoch and
escalation_closed_epoch set) cloned from a real record produced through the API,
mirroring the production retained store. Two byte-identical stores; each tick pass
instrumented for wall-clock time, `fm_pending_reply_get` record reads (each read =
`$( )` subshell over a `grep|tail|cut` subprocess chain), and
`fm_pending_reply_close_escalation` calls (each = per-correlation lock + sourcing
`bin/fm-wake-lib.sh`).

| pass over the same 2283-record store | record reads (get_calls) | close_escalation calls (locks) | wall clock |
| --- | ---: | ---: | ---: |
| BEFORE (base `60915d9` tick) | 13,698 (6 per record) | 2,283 (1 per record) | 171,271 ms (~171 s) |
| AFTER (target tick, pass 1) | 0 | 0 | 1,454 ms |
| AFTER (target tick, pass 2, steady state) | 0 | 0 | 905 ms (~0.9 s) |
| AFTER with `PATH=/nonexistent` | builtin-only pass | — | OK, no failure |

Result: ~171 s → ~0.9-1.5 s per pass on 2283 settled records (~120-190× faster), with
zero subprocesses and zero per-correlation lock acquisitions on the settled path,
comfortably inside the 300 s `.last-watcher-beat` grace. (Field report cited ~202 s
before / ~1 s after; sandbox reproduces both orders of magnitude.)

The 6-reads-per-record figure matches the field estimate (~13,000 subprocess launches
per poll for ~2539 records when each read spawns grep|tail|cut).

## 3. No behavior change for open escalations

Three resolved records with a still-open escalation (escalation_closed_epoch empty,
close deferred as in the unit test) were closed by one tick pass under BOTH
implementations on identical stores: escalation_closed_epoch set and the guarded
`resolved [key=pending-reply-<corr>]: pending-reply-resolved:` decision line appended
exactly once per record. Real close work (lock + guarded status append) still runs and
costs real time in both (BEFORE ~1.09 s / AFTER ~0.74 s for 3 real closes) — only the
settled no-op path was made lock/subprocess-free.

## 4. Safety-gate scope

Diff touches only the tick dispatch read path and adds regression tests. No gate,
lock-ordering, escalation-policy, grace, reply-window, retention, or ghost-close
logic was modified. `git status` clean after evidence collection.
