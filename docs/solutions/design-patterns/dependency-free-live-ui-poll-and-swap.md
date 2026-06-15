---
title: Dependency-free live UI updates in a Rails engine (poll-and-swap)
date: 2026-06-15
category: docs/solutions/design-patterns/
module: MaintenanceOnSteroids (shared views)
problem_type: design_pattern
component: rails_view
severity: medium
applies_when:
  - "Building a Rails engine/gem that must not impose a JS framework on host apps"
  - "Live DOM updates needed on a polling cadence without Turbo/Hotwire/Stimulus"
  - "One or more named page regions need in-place refresh without a full reload"
related_components:
  - background_job
  - rails_controller
tags:
  - vanilla-js
  - polling
  - live-ui
  - dom-swap
  - rails-engine
  - no-hotwire
  - abort-controller
---

# Dependency-free live UI updates in a Rails engine (poll-and-swap)

## Context

A Rails engine mounts inside arbitrary host apps with one `mount` line. The engine can't assume the host's front-end stack — some run Hotwire/Turbo, some Stimulus, some React, some nothing. So engine views **cannot** depend on `Turbo.visit`, `<turbo-frame>`, or Stimulus controllers, and adding `turbo-rails` as a gem dependency would break host-app neutrality.

Yet a maintenance dashboard genuinely needs live updates — run status, progress bars, active-run counts. The naive fix, `setInterval(() => location.reload(), 5000)`, works but is jarring: it jumps scroll to the top, drops focus from inputs/links, and hammers the endpoint forever on a 500.

This engine has **no** turbo/hotwire/stimulus anywhere (gemspec, Gemfile, dummy app, layout — all verified) and still does live updates, via one self-contained partial.

## Guidance

A single shared partial, `app/views/maintenance_on_steroids/shared/_auto_refresh.html.erb`, emits a self-contained vanilla-JS IIFE — no external file, import, or controller class. Parameterized at the call site:

- `target_ids:` (required) — array of DOM ids whose `innerHTML` is swapped from the freshly fetched page.
- `stop_when_gone:` (optional) — a DOM id; once a re-fetched page no longer contains it, polling tears itself down.

The id list is embedded safely with `escape_javascript` then `JSON.parse` — never raw `<%==`:

```erb
var TARGET_IDS = JSON.parse('<%= j target_ids.to_json %>');
var STOP_WHEN_GONE = JSON.parse('<%= j (local_assigns[:stop_when_gone] || "").to_json %>');
```

The poll cycle (condensed from the real partial):

```javascript
function refresh() {
  if (document.hidden) { return; }              // 1. pause in background tabs
  if (inFlight !== null) { inFlight.abort(); }  // 2. cancel prior in-flight fetch
  var controller = new AbortController();
  inFlight = controller;

  fetch(window.location.href, { headers: { "Accept": "text/html" }, signal: controller.signal })
    .then(function(res) { if (!res.ok) throw new Error("HTTP " + res.status); return res.text(); })
    .then(function(html) {
      inFlight = null; consecutiveFailures = 0;
      var doc = new DOMParser().parseFromString(html, "text/html");   // 3. parse to DOM
      TARGET_IDS.forEach(function(id) {
        var fresh = doc.getElementById(id), current = document.getElementById(id);
        // 4. swap innerHTML, but skip if the user is focused inside this target
        if (current && fresh && !current.contains(document.activeElement)) {
          current.innerHTML = fresh.innerHTML;
        }
      });
      // 5. self-terminate once the sentinel disappears from the fetched page
      if (STOP_WHEN_GONE && !doc.getElementById(STOP_WHEN_GONE)) { teardown(); }
    })
    .catch(function(err) {
      inFlight = null;
      if (err && err.name === "AbortError") { return; }   // intentional abort, not a failure
      consecutiveFailures += 1;
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) { teardown(); }  // 6. bound failures
    });
}
```

Teardown handles every exit path uniformly and is wired to `pagehide` (the real trigger, since there's no Turbo) plus `turbo:before-visit`/`turbo:before-cache`:

```javascript
function teardown() {
  if (timer !== null) { clearInterval(timer); timer = null; }
  if (inFlight !== null) { inFlight.abort(); inFlight = null; }
  document.removeEventListener("turbo:before-visit", teardown);
  document.removeEventListener("turbo:before-cache", teardown);
  window.removeEventListener("pagehide", teardown);
}
```

The `turbo:before-*` listeners are **defensive no-ops** — those events never fire in a non-Turbo host, but registering them means the partial drops into a Turbo host app without leaking stacked intervals across Drive navigations. Nothing in the partial requires Turbo.

**Sentinel self-terminate** — render a hidden marker only while there's active work, and the poller stops on its own once it's gone:

```erb
<%# jobs/index.html.erb %>
<% if @active_run_counts.values.sum.positive? %>
  <span id="mos-active-sentinel" hidden></span>
<% end %>

<% if @active_run_counts.values.sum.positive? %>
  <%= render "maintenance_on_steroids/shared/auto_refresh",
             target_ids: ["jobs-list"], stop_when_gone: "mos-active-sentinel" %>
<% end %>
```

## Why This Matters

- **Zero dependencies** — only `fetch`, `AbortController`, `DOMParser`, `setInterval`; works in any host app regardless of its JS stack.
- **No visual disruption** — only the named sections' `innerHTML` is replaced, so no scroll jump and no flicker of the rest of the page.
- **Focus preserved** — the `current.contains(document.activeElement)` guard skips swapping a region the user is interacting with (a focused View/Pause link), instead of ripping it out mid-click.
- **Bounded failure** — five consecutive errors tears the poller down, so a 500ing endpoint isn't hammered forever; intentional `AbortError`s don't count.
- **Self-terminating** — the sentinel means an idle page isn't still polling minutes after its last run finished.
- **Concurrency-safe** — a fresh `AbortController` per cycle cancels the prior in-flight fetch, so slow responses can't pile up or land out of order.

## When to Apply

**Good fit:** live dashboards / status lists in a mountable engine or gem; read-only sections that re-render cheaply server-side; pages that should stop polling once work completes; anywhere you can't assume the host app's front-end framework.

**Not a good fit:** sub-second / high-frequency updates or large payloads — the cost is a full-page HTML fetch + parse per tick. At that scale, move to a dedicated JSON endpoint. The engine's own `runs/show.html.erb` poller is the contrasting approach: it hits a dedicated `GET /runs/:id/status` JSON endpoint at 2s, surgically patches individual nodes (`#status-badge`, `#progress-bar`), and reloads on a settled-state transition — appropriate when the update surface is a small, well-defined set of fields and field-level logic is non-trivial, at the cost of a separate controller action + serializer. Use `_auto_refresh` when the update surface is a whole section and the existing page action is already the right source of truth (no extra code).

## Examples

Before — naive full reload (scroll jump, lost focus, hammers on error):

```javascript
setInterval(() => location.reload(), 5000);
```

After — dashboard (always-on while open, two targets):

```erb
<%= render "maintenance_on_steroids/shared/auto_refresh",
           target_ids: ["dashboard-stats", "active-runs-section"] %>
```

After — jobs index (conditional + self-terminating): the partial isn't even emitted when idle; while active it polls `#jobs-list` and stops the first time a refreshed page lacks `#mos-active-sentinel` (see Guidance above).

## Related

- `docs/solutions/runtime-errors/unguarded-instrumentation-corrupts-run-status-2026-06-15.md` — unrelated domain (instrumentation), listed only to note no overlap.
- `AGENTS.md` (Conventions) carries the two-sentence summary of this pattern and points here for the full rationale.
