---
title: Pin third-party CDN assets with Subresource Integrity on privileged engine views
date: 2026-06-15
category: docs/solutions/best-practices/
module: MaintenanceOnSteroids (source viewer / engine views)
problem_type: best_practice
component: rails_view
severity: medium
applies_when:
  - "Loading a third-party asset (JS/CSS) from a CDN in a mountable Rails engine or gem view"
  - "The surface is privileged — an admin/ops dashboard that runs tasks, reads uploads, or shows data"
  - "The CDN URL pins a specific release (e.g. `@11.9.0`) rather than a floating tag"
tags:
  - sri
  - subresource-integrity
  - cdn
  - supply-chain
  - security
  - rails-engine
  - admin-surface
---

# Pin third-party CDN assets with Subresource Integrity on privileged engine views

## Context

The engine's source viewer (`app/views/maintenance_on_steroids/jobs/source.html.erb`) optionally syntax-highlights Ruby with highlight.js loaded from the jsDelivr CDN. The dashboard is a **privileged surface**: it runs maintenance tasks, reads uploaded blobs, and lists artifacts. The script tag carried `crossorigin="anonymous"` but **no `integrity=` hash**, so a compromised or MITM'd CDN response would execute attacker-controlled JS in the dashboard origin — able to exfiltrate the session cookie / CSRF token or trigger task runs. `crossorigin` without `integrity` buys nothing here.

This is the security rule for the one acknowledged exception to the engine's zero-external-dependency design goal (see [Related](#related)).

## Guidance

Any third-party CDN asset loaded in a privileged engine view must carry a **`sha384` Subresource Integrity hash** plus `crossorigin="anonymous"` (SRI enforcement requires the CORS attribute). Compute the hash from the exact bytes the pinned URL serves:

```bash
curl -fsSL "<asset-url>" | openssl dgst -sha384 -binary | openssl base64 -A
```

**Single-source the version** so the script `src`, the (JS-built) stylesheet URL, and the integrity hash cannot drift apart. One ERB local drives all three:

```erb
<% hljs_version   = "11.9.0" %>
<% hljs_integrity = "sha384-F/bZzf7p3Joyp5psL90p/p89AZJsndkSoGwRpXcZhleCWhd8SnRuoYo4d0yirjJp" %>
<script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@<%= hljs_version %>/build/highlight.min.js"
        integrity="<%= hljs_integrity %>"
        crossorigin="anonymous"></script>
```

The `integrity` value is the one thing that does **not** derive from the version automatically — leave a comment naming the recompute command so a version bump can't silently ship a stale hash (which fails closed: the browser refuses the asset and highlighting degrades to plain text).

## Why This Matters

- **A privileged surface is a high-value injection target.** On an admin dashboard, arbitrary CDN JS isn't a defacement risk — it's session/CSRF theft and unauthorized task execution.
- **SRI fails safe.** A tampered (or stale-hashed) asset is refused by the browser; the feature degrades gracefully rather than executing untrusted code.
- **Drift is the real-world failure mode.** The common regression isn't "forgot SRI once" — it's bumping the CDN version and leaving the old hash, or updating the script URL but not the JS-built stylesheet URL. Single-sourcing the version removes two of the three drift paths; the comment guards the third.
- **No CSP backstop here.** The dashboard ships no Content-Security-Policy, so SRI is the *only* integrity control on the CDN script. That raises, not lowers, the bar for getting SRI right.

## When to Apply

- Any CDN `<script>` or `<link rel="stylesheet">` in an engine/gem view, especially on admin/ops surfaces.
- Skip only if the asset is vendored into the app's own assets (then there's no CDN trust boundary — preferred when feasible, but heavier for an optional progressive-enhancement like syntax highlighting).
- A theme/asset URL built dynamically in JS (e.g. the highlight.js light/dark stylesheet) is hard to SRI-pin and is lower risk (CSS, not executable) — acceptable residual risk to leave unpinned; pin the executable script first.

## Examples

Before — executable CDN script with no integrity guard:

```erb
<script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"
        crossorigin="anonymous"></script>
```

After — version single-sourced, script SRI-pinned, recompute path documented:

```erb
<%# Bumping hljs_version? Recompute hljs_integrity:
    curl -fsSL <src-url> | openssl dgst -sha384 -binary | openssl base64 -A %>
<% hljs_version   = "11.9.0" %>
<% hljs_integrity = "sha384-F/bZzf7p3Joyp5psL90p/p89AZJsndkSoGwRpXcZhleCWhd8SnRuoYo4d0yirjJp" %>
<script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@<%= hljs_version %>/build/highlight.min.js"
        integrity="<%= hljs_integrity %>"
        crossorigin="anonymous"></script>
```

A request spec guards the attribute so a future template edit (or a forgotten hash recompute that drops the attribute) is caught:

```ruby
it "pins the highlight.js CDN script with a Subresource Integrity hash" do
  get "/maintenance/jobs/UpdateUsersTask/source"
  expect(response.body).to match(/highlight\.min\.js"\s+integrity="sha384-/)
end
```

## Related

- `docs/solutions/design-patterns/dependency-free-live-ui-poll-and-swap.md` — establishes the zero-external-dependency design goal for engine views. SRI is the required mitigation for the one CDN exception (the optional syntax highlighter) to that rule.
