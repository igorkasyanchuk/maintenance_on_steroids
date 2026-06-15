---
title: "Unguarded ActiveSupport::Notifications.instrument calls corrupt Run status on subscriber exceptions"
date: 2026-06-15
category: runtime-errors
module: "Instrumentation / RunJob"
problem_type: runtime_error
component: background_job
severity: high
symptoms:
  - "A just-completed Run is overwritten to errored in the DB when any lifecycle subscriber raises, because the exception propagates into RunJob's rescue block"
  - "Runs reach paused or cancelled state in the DB but are then overwritten to errored before tooling can observe the correct status"
  - "A subscriber raise on :started causes an endless retry storm — the run errors and re-queues but :started never re-fires on retry because first_start is false"
  - "Exceptions from :enqueued or :resumed subscribers escape unrescued into the controller, producing HTTP 500 responses"
  - "after_complete callbacks and artifact flush are silently skipped when the :succeeded subscriber raises"
root_cause: wrong_api
resolution_type: code_fix
related_components:
  - rails_model
tags:
  - active-support-notifications
  - instrumentation
  - background-job
  - error-handling
  - run-lifecycle
  - safe-instrument
---

# Unguarded ActiveSupport::Notifications.instrument calls corrupt Run status on subscriber exceptions

## Problem

`ActiveSupport::Notifications.instrument` re-raises any exception thrown by a subscriber. The engine's lifecycle instrumentation (`Instrumentation.instrument(:started|:succeeded|:paused|:cancelled|:errored, run)`) was called unguarded on every state-mutation path in `RunJob` and `Run`, so a single misbehaving subscriber could corrupt persisted run state or crash the controller.

## Symptoms

- A just-completed (or paused/cancelled) Run shows as `errored` in the database. The instrument call sits before/within the job's `rescue => e`, so a subscriber exception propagates into that rescue and rewrites the terminal status to `errored` with the subscriber's message.
- A pause or cancel is silently lost: the instrument call fires *after* `@run.update!(status: "paused"/"cancelled")`; if it raises, the rescue resets status to `errored`, discarding the operator's intent.
- A `:started` retry storm: a subscriber raise on `:started` errors the run and the adapter retries; `:started` never re-fires on retry (`first_start` is false), so the run errors-and-requeues until max retries.
- HTTP 500 from the controller: `Run#enqueue!`/`#resume!`/`#cancel!` call `instrument` directly, so a subscriber exception escapes through the controller action (no rescue there).
- `after_complete` callbacks and artifact auto-flush are silently skipped when the `:succeeded` subscriber raises.

## What Didn't Work

The original unguarded instrumentation **passed the entire test suite green** — no test subscriber raises, so the happy path never exercised the failure mode. `AS::Notifications` only becomes dangerous when a *real* subscriber misbehaves. Green specs gave false confidence; the bug was invisible to automated testing and was caught only by adversarial reasoning about `AS::Notifications` re-raise semantics ("what happens if a subscriber throws?") during code review — not by any failing spec. (session: caught by reliability + adversarial reviewers, P1, confidence 100.)

## Solution

Add a `safe_instrument` helper in both `RunJob` and `Run`, mirroring the existing `safe_callback` pattern, and route every `Instrumentation.instrument` call through it.

Before — unguarded, in `RunJob#check_status!`:

```ruby
@run.update!(status: "paused")
Instrumentation.instrument(:paused, @run)   # subscriber exception escapes here
```

After — wrapped:

```ruby
@run.update!(status: "paused")
safe_instrument(:paused, @run)              # exception caught and logged, never re-raised
```

Helper in `app/jobs/maintenance_on_steroids/run_job.rb`:

```ruby
def safe_instrument(event, run, extra = {})
  MaintenanceOnSteroids::Instrumentation.instrument(event, run, extra)
rescue => e
  Rails.logger.error "[MaintenanceOnSteroids] Instrumentation error (#{event}): #{e.message}"
end
```

Helper in `app/models/maintenance_on_steroids/run.rb` (model variant — `self` is the run):

```ruby
def safe_instrument(event, extra = {})
  Instrumentation.instrument(event, self, extra)
rescue => e
  Rails.logger.error "[MaintenanceOnSteroids] Instrumentation error (#{event}): #{e.message}"
end
```

## Why This Works

`instrument` runs the block and notifies all subscribers; if any subscriber raises, the exception propagates to the caller. Because the run's terminal-status write (`update!(status: ...)`) precedes the instrument call, an unguarded raise reaches the job's outer `rescue => e`, which unconditionally overwrites status to `errored`. Wrapping at the `safe_instrument` boundary isolates subscriber exceptions from the control-flow path, enforcing the invariant: **instrumentation must never affect run outcomes.**

## Prevention

- Never call `ActiveSupport::Notifications.instrument` unguarded on a path where a downstream raise can corrupt persistent state. The same rule applies to any observer, hook, or callback that may re-raise.
- Treat all lifecycle notifications (`:started`, `:paused`, `:cancelled`, `:succeeded`, `:errored`) as best-effort, side-effect-only operations — wrap them in a rescue-and-log helper.
- Add a regression test that subscribes a deliberately raising block and asserts the run still reaches the correct terminal status. Example: subscribe to `"paused.maintenance_on_steroids"` with `raise "bad subscriber"`, run a pausing task, assert `run.reload.status == "paused"`. This would have caught the bug immediately.
- General principle: any hook crossing a trust boundary (user-supplied or third-party subscribers) must be firewalled with the same rescue-and-log wrapper used for `safe_callback`. Observability infrastructure must never become a reliability hazard.

## Related Issues

- None — first documented solution in this repository.
