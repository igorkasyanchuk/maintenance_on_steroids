# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/igorkasyanchuk/maintenance_on_steroids/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/igorkasyanchuk/maintenance_on_steroids/releases/tag/v0.1.0
