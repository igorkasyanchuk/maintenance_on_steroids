# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **A blank HTTP Basic password no longer counts as configured.** The check
  added in 0.1.1 compared only against the shipped `"secret"`, so a nil
  password -- the result of a missing or misspelled credentials key, which is
  exactly the pattern the generated initializer recommends -- passed as
  configured, booted production without a warning, and let `admin` plus an
  empty password through, because `secure_compare(supplied, "")` matches. Blank
  is now treated as unconfigured, and the controller refuses to authenticate at
  all while the configured password is blank.

### Fixed

- **Artifact previews no longer crash the run page on non-ASCII content.**
  Two separate encoding faults: `data_blob` is ASCII-8BIT, so interpolating a
  CSV cell holding an accented character into the UTF-8 template raised
  `Encoding::CompatibilityError` at any size; and `byteslice` could cut a
  multibyte character in half, after which matching the line-trim regex raised
  `ArgumentError: invalid byte sequence in UTF-8`. Slices are now transcoded
  and scrubbed before use.
- **A single-line artifact no longer previews as empty.** The line-trim regex
  matched the entire slice when it contained no newline, blanking the preview
  of any minified or unbroken payload over the cap.
- **jsonb previews respect the cap on rows with no recorded metadata.**
  `byte_size` fell back to `data_blob`, which is nil for jsonb and text, so
  `preview_truncated?` answered false, the whole document was generated, and
  the byte slice then cut it into unparseable JSON with no truncation notice.
  `byte_size` now measures the column that holds the payload, and jsonb
  trimming keys off the entry count directly.
- **`database_role` no longer wraps a callable task's `call`.** It scopes the
  collection scan; running a callable task's body -- mostly writes -- under
  `:reading` would fail on a real replica. Callable tasks use
  `Task#with_database_role` for their own reads.
- **`job_config` is resolved once per run instead of once per record.** It
  allocates a fresh `JobConfig` whenever a task declares no `job` block, so the
  per-record role check meant one throwaway object per processed record.
- **`Run#resume!` keeps the original failure.** It cleared `error_message` and
  `error_backtrace` before attempting to enqueue, so a resume that itself
  failed destroyed the only record of why the run died. They are now cleared
  only once the job is really queued.
- **`Run#resume!` raises `MaintenanceOnSteroids::EnqueueFailed`** rather than
  the raw exception, and the controller catches only that -- other errors reach
  the host app's error reporting instead of being redirected as "Run could not
  be enqueued".
- **Scalar form inputs reject nested structures.** A client posting
  `task_params[name][x]=1` where a string was declared handed the task a
  Parameters object; it is now rejected alongside out-of-range select values.

### Changed

- `pg` moved to an optional bundler group, so the resolved bundle no longer
  depends on `DB` being set in the shell; switching between the SQLite and
  PostgreSQL suites no longer needs a re-install.
- The Postgres test setup no longer drops every table in the database before
  loading the schema (schema.rb already uses `force: :cascade`), which removed
  a way for concurrent rspec processes to clobber each other.
- Connection values in the dummy app's `database.yml` are quoted, so a password
  containing `:`, `#`, `%` or `@` no longer produces a YAML syntax error.

## [0.1.1] - 2026-08-21

### Security

- **The engine now refuses to boot in production with no access control.**
  Every layer is opt-in and the dashboard can start any task against your
  database, so an unconfigured install was silently wide open. HTTP Basic left
  on the shipped `"secret"` password counts as *unconfigured* -- otherwise the
  most dangerous setup would be the quietest one. Hosts that gate the dashboard
  elsewhere (reverse proxy, VPN, middleware) opt out explicitly with
  `config.allow_insecure_dashboard = true`. Outside production this warns
  instead of raising.
- **`maintenance_on_steroids:install` now generates the initializer**, with
  each access-control layer laid out and commented.
- **Select inputs are validated server-side.** A `<select>` only constrains the
  browser; a posted value outside the declared `options` is now rejected
  instead of being handed to the task.

### Fixed

- **Artifacts are no longer lost when a worker is interrupted.**
  `ActiveJob::Continuation::Interrupt` subclasses `Exception`, so it was
  invisible to `RunJob`'s `rescue` and buffered artifact rows written since the
  job started were discarded on every SIGTERM/deploy while the cursor kept
  advancing -- the run still reported `completed`. Flushing now happens in an
  `ensure`, covering every exit path.
- **`csv` is now a declared runtime dependency.** It left Ruby's default gems
  in 3.4, and `csv_artifact.rb` requires it at load time, so the gem failed to
  boot in host apps on Ruby >= 3.4 that did not list `csv` themselves.
- **An errored run can be resumed from the dashboard.** A single transient
  failure (deadlock, lock timeout) previously stranded a run mid-write with no
  way to continue. `Run#resumable?` now covers `errored` as well as `paused`,
  and resuming clears the previous error. The record that raised is retried;
  records already past the cursor are not.
- **`resume_errors_after_advancing` is disabled on `RunJob`.** Continuable was
  re-enqueuing a job that this gem had already marked terminal, so the retry
  fired, no-opped against the guard, and left the run looking retried but never
  advancing.
- **`Run#resume!` no longer strands a run in `enqueued`.** The status
  compare-and-set happened before `enqueue!`, so a queue outage or a deleted
  task class left the run enqueued with no job behind it (and 500'd the
  controller). Enqueue failures now roll the run back to `errored`.
- **An interrupted run is marked `enqueued` while it waits to be resumed**, so
  `Run.reap_stale!` no longer mistakes its frozen `updated_at` for a dead
  worker and kills a run that was about to continue.
- **`RunJob` discards `ActiveRecord::RecordNotFound`** instead of retrying a
  job for a deleted run ~21 times.
- **Artifact downloads 404 for non-file artifacts** instead of returning a
  200 with a zero-byte `.bin`.
- **Inline artifact previews are capped** at `Artifact::PREVIEW_BYTES` (256 KB)
  and report truncation. Parsing a multi-hundred-MB export to show its first
  100 rows could exhaust the web process.
- **Reading an unwritten `:file` artifact no longer re-queries** on every
  access (once per record inside a collection task).
- **`database_role` actually reaches the replica.** `collection` returns a lazy
  `Relation`, so the documented `with_database_role(:read) { ... }` wrapper
  restored the connection before a single row was fetched and the whole scan
  ran on the primary. Declare it instead -- `job { database_role :reading }` --
  and RunJob holds the role open for the entire scan, stepping back to
  `:writing` for `process` and for its own cursor/progress writes.
- **`pause!` and `cancel!` are compare-and-set**, like `resume!`. A pause
  clicked as the job completed could overwrite `completed` with `pausing`,
  which nothing but `reap_stale!` would ever clear.
- **Oversized jsonb previews no longer generate the whole document** before
  slicing it -- the structure is trimmed to `Artifact::PREVIEW_ENTRIES`
  top-level entries first, which was the allocation the byte cap existed to
  avoid.

### Changed

- The engine now warns at boot when **no** access control is configured
  (`error` level in production). Previously only the partially-configured case
  warned, leaving the fully open dashboard silent.
- The dashboard stops polling once no run is active, instead of re-rendering
  itself and its aggregate queries every 4 seconds indefinitely.
- The highlight.js theme stylesheets on the source viewer are SRI-pinned, like
  the script already was.
- CI runs the suite against PostgreSQL as well as SQLite (`DB=postgres`), so
  `json`/`bytea` behaviour and real row locking are covered. The install
  generator has a spec.

## [0.1.0] - 2026-07-25

Initial release.

### Added

- **Task DSL** built on `MaintenanceOnSteroids::Task`
  - Collection tasks (`collection` + `process`) and callable tasks (`call`)
  - `about` block for title, description and owner metadata
  - `form` block with typed inputs: string, text, integer, float, boolean,
    date, datetime, select and file (`:blob`) uploads
  - `artifact` block for declared outputs: `:jsonb`, `:text`, `:csv`, `:file`
  - `job` block for per-task queue name and priority
  - Lifecycle callbacks: `after_start`, `after_pause`, `after_interrupt`,
    `after_cancel`, `after_complete`, `after_error`
  - `with_database_role` for reading from a replica inside a task
- **Automatic resumption** via `ActiveJob::Continuable` — a DB-backed cursor is
  written after every processed record, so Sidekiq restarts and pause/resume
  cycles never reprocess work already done
- **Pause / resume / cancel** with compare-and-set transitions, so concurrent
  requests cannot double-enqueue or overwrite a requested stop
- **Web dashboard** mounted as a Rails engine
  - Stats overview, active runs, run history with pagination
  - Live progress bars and status badges via JSON polling (no build step,
    no JavaScript dependencies)
  - Estimated time remaining, extrapolated from the current processing rate
  - Task source viewer with optional syntax highlighting (CDN + SRI pinned)
  - Dark and light themes, persisted in `localStorage`
- **Artifacts** stored in the database: JSON documents, text logs, CSV exports
  and binary blobs, previewable and downloadable from the UI, auto-flushed on
  completion, pause and cancel
- **Authentication and access control**, layered and off by default: HTTP Basic
  (constant-time comparison), a custom `authentication` hook for
  Devise/Warden/etc., and `verify_access_proc` for role- or IP-based checks
- **User tracking** — records who triggered each run, with a configurable
  display formatter
- **Instrumentation** — `ActiveSupport::Notifications` events for every
  lifecycle transition (`enqueued`, `started`, `paused`, `resumed`,
  `cancelled`, `succeeded`, `errored`); a raising subscriber can never corrupt
  a run's status
- **`Run.reap_stale!`** to recover runs whose worker died mid-execution
- **Generators** — `maintenance_on_steroids:install` (migration, task
  directory, engine mount) and `maintenance_on_steroids:job` (new task)

### Requirements

- Rails >= 8.1 (`ActiveJob::Continuable` ships in 8.1)
- Ruby >= 3.2

[Unreleased]: https://github.com/igorkasyanchuk/maintenance_on_steroids/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/igorkasyanchuk/maintenance_on_steroids/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/igorkasyanchuk/maintenance_on_steroids/releases/tag/v0.1.0
