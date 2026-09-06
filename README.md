# Maintenance on Steroids

![Maintenance on Steroids dashboard walkthrough](docs/demo.gif)

A powerful maintenance task runner for **Rails 8.1+** that leverages `ActiveJob::Continuable` for safe, resumable background processing. Think of it as a batteries-included toolkit for one-off data migrations, batch updates, CSV exports, and any maintenance work your app needs.

**Built-in web dashboard** with dark/light themes, live progress tracking, pause/resume/cancel controls, source code viewer, and artifact downloads.

> [!IMPORTANT]
> **Requires Rails >= 8.1 and Ruby >= 3.2.** Resumption is built on `ActiveJob::Continuable`, which ships in Rails 8.1 — the gem will not install on earlier Rails versions.

## Features

- **Collection & callable tasks** -- iterate over ActiveRecord relations or run one-off jobs
- **Automatic resumption** -- cursor-based progress tracking survives Sidekiq restarts and pause/resume cycles without reprocessing records
- **Rich DSL** -- typed form inputs, named artifacts, lifecycle callbacks, queue configuration, task metadata
- **Live dashboard** -- auto-refreshing stats and active runs, real-time progress bars, status badges, run history, and source code viewer
- **Estimated time remaining** -- live ETA for pending records, extrapolated from the current processing rate
- **Artifacts** -- store JSON results, export CSV/binary files, downloadable from the UI, with per-run indicators on the dashboard
- **Pause / Resume / Cancel** -- safely interrupt long-running tasks mid-execution
- **Instrumentation** -- `ActiveSupport::Notifications` events for every run lifecycle transition
- **User tracking** -- records who triggered each run with configurable display
- **Authentication & access control** -- layered, off by default: HTTP Basic (constant-time compare), a custom auth hook for Devise/Warden/etc., and a `verify_access_proc` for role- or IP-based authorization ([jump to setup](#authentication--access-control))
- **Dark & light themes** -- toggle with one click, persisted in localStorage

## Requirements

- **Rails >= 8.1** — hard requirement; resumption depends on `ActiveJob::Continuable`, introduced in Rails 8.1
- **Ruby >= 3.2**

## Installation

Add the gem to your Gemfile:

```ruby
gem "maintenance_on_steroids"
```

Run the install generator:

```bash
bundle install
rails generate maintenance_on_steroids:install
rails db:migrate
```

This will:
1. Create the database migration for runs and artifacts tables
2. Create the `app/maintenance/` directory for your task classes
3. Mount the engine at `/maintenance` in your routes

## Quick Start

### Generate a task

```bash
rails generate maintenance_on_steroids:job BackfillUserNames
```

This creates `app/maintenance/backfill_user_names.rb`:

```ruby
class BackfillUserNames < MaintenanceOnSteroids::Task
  about do
    title "Backfill User Names"
    description "TODO: Add description"
  end

  def collection
    User.where(name: nil)
  end

  def process(record)
    record.update!(name: record.email.split("@").first)
  end
end
```

### Generate a callable (one-off) task

```bash
rails generate maintenance_on_steroids:job ClearExpiredTokens --collection=false
```

```ruby
class ClearExpiredTokens < MaintenanceOnSteroids::Task
  about do
    title "Clear Expired Tokens"
    description "TODO: Add description"
  end

  def call
    Token.where("expires_at < ?", Time.current).delete_all
  end
end
```

### Run it

Start your Rails server and visit **`/maintenance`**. You'll see the dashboard with your tasks listed. Click a task, then "New Run" to start it.

## Task DSL

### About

Describe your task for the dashboard:

```ruby
class MyTask < MaintenanceOnSteroids::Task
  about do
    title "My Task"
    description "Does something useful"
    owner "Backend Team"
  end
end
```

If `title` is omitted, the class name is used (e.g. `MyTask` becomes "My Task").

### Collection tasks

Define `collection` (returns an `ActiveRecord::Relation`) and `process` (handles one record):

```ruby
class DeactivateOldUsers < MaintenanceOnSteroids::Task
  about do
    title "Deactivate Old Users"
    description "Deactivates users who haven't logged in for a year"
  end

  def collection
    User.where("last_sign_in_at < ?", 1.year.ago).where(active: true)
  end

  def process(user)
    user.update!(active: false)
  end
end
```

The engine iterates over records using `find_each`, tracks progress automatically, and persists a cursor after each record. If the job is interrupted (Sidekiq restart, pause, or deploy), it resumes from exactly where it left off -- **no records are processed twice**.

### Callable tasks

For one-off jobs that don't iterate over a collection, define `call`:

```ruby
class RecalculateStats < MaintenanceOnSteroids::Task
  about do
    title "Recalculate Stats"
    description "Rebuilds all cached statistics"
  end

  def call
    StatsService.rebuild_all
  end
end
```

### Form Inputs

Accept parameters from the UI with typed inputs:

```ruby
class UpdateUserAges < MaintenanceOnSteroids::Task
  form do
    input :name, type: :string, required: true, placeholder: "Filter by name"
    input :new_age, type: :integer, required: true, default: 25
  end

  def collection
    User.where(name: params[:name])
  end

  def process(user)
    user.update!(age: params[:new_age])
  end
end
```

The `params` proxy provides typed access -- `:integer` values are cast to `Integer`, `:boolean` to `true/false`, etc.

**Supported input types:**

| Type | HTML Element | Cast |
|------|-------------|------|
| `:string` | `<input type="text">` | String |
| `:integer` | `<input type="number">` | Integer |
| `:float` | `<input type="number" step="any">` | Float |
| `:boolean` | `<input type="checkbox">` | Boolean |
| `:text` | `<textarea>` | String |
| `:date` | `<input type="date">` | Date |
| `:datetime` | `<input type="datetime-local">` | Time |
| `:blob` | `<input type="file">` | Binary |
| `:select` | `<select>` | String |

**Input options:**

```ruby
input :role,
  type: :select,
  options: %w[admin user moderator],
  required: true,
  default: "user",
  label: "User Role",
  placeholder: "Choose a role",
  help_text: "The role to assign to matched users"
```

**File uploads (`type: :blob`):** the uploaded file is stored with the run (as an `input` artifact) and read through `params`:

- `params[:name]` -- the raw file **bytes** (a `String`), or `nil` if nothing was uploaded
- `params.file_name(:name)` -- the original filename
- `params.content_type(:name)` -- the uploaded MIME type

```ruby
class CountLetterATask < MaintenanceOnSteroids::Task
  form do
    input :file, type: :blob, required: true, help_text: "CSV/text file to scan"
  end

  artifact :result, type: :jsonb, default: {}

  def call
    content = params[:file].to_s   # raw bytes of the upload

    artifacts.save(:result, {
      "file_name" => params.file_name(:file),
      "content_type" => params.content_type(:file),
      "bytes" => content.bytesize,
      "a_count" => content.count("aA")   # letter "a", case-insensitive
    })
  end
end
```

Uploads are read into memory and capped by `config.max_upload_size` (see Configuration). Need a CSV as rows? `CSV.parse(params[:file])`.

### Artifacts

Store output data (JSON, files, text) that persists with the run:

```ruby
class ExportUsers < MaintenanceOnSteroids::Task
  about do
    title "Export Users to CSV"
  end

  artifact :csv_file, type: :file, file_name: "users.csv"

  def call
    csv_data = CSV.generate do |csv|
      csv << %w[id name email]
      User.find_each do |user|
        csv << [user.id, user.name, user.email]
      end
    end

    artifacts[:csv_file] = csv_data
  end
end
```

The generated file is downloadable from the run's detail page in the UI.

**Artifact types:**

| Type | Storage | Use case |
|------|---------|----------|
| `:jsonb` | JSON column | Structured results, counters, logs |
| `:file` | Binary blob | PDFs, images, pre-rendered files |
| `:text` | Text column | Plain text output |
| `:csv` | Binary blob | Row-oriented exports, table-previewed in the UI |

An unknown `type:` raises `ArgumentError` at load time, so typos surface immediately.

**Declaration options** (all types): `label:` (human name shown in the UI, defaults to the humanized artifact name), `description:` (shown under the artifact on the run page), `content_type:` (download MIME -- otherwise inferred from `file_name`), plus `default:`, `file_name:`, and `headers:` (CSV).

**Writing artifacts -- two styles:**

1. **Explicit (`save`)** -- persist a whole value immediately. The type comes from the declaration, so one call covers every kind. This is the simplest path and never relies on auto-flush:

```ruby
artifacts.save(:json_data, { name: "Igor", age: 40 })  # jsonb
artifacts.save(:export, rows)                           # csv (array of rows, or a String)
artifacts.save(:log, "done")                            # text
# artifacts[:json_data] = { ... } is an alias of save
```

2. **Accumulator (`<<` / in-place)** -- build the value incrementally across records; the job auto-flushes it (see Auto-flush below). Best for resumable tasks that accrue output row by row:

```ruby
artifacts.export << [user.id, user.name]   # append a CSV row
artifacts.result[user.id.to_s] = { ok: true }  # mutate a JSONB hash in place
```

**Access** -- `artifacts[:name]` and method style are equivalent:

```ruby
artifacts[:result]["k"] = v
artifacts.result["k"]  = v   # same thing, reads nicer
```

**JSONB artifacts** behave like a hash:

```ruby
artifact :result, type: :jsonb, default: {}

def process(user)
  user.update!(active: false)
  artifacts.result[user.id.to_s] = { deactivated: true }
end
```

**CSV artifacts** are append-oriented and render to a downloadable `.csv`:

```ruby
artifact :export, type: :csv, headers: %w[id name email], description: "All users"

def call
  User.find_each { |u| artifacts.export << [u.id, u.name, u.email] }
  # auto-flushed on completion; previewed as a table on the run page
end
```

**Auto-flush:** this backs the **accumulator** style only -- you don't need to call `artifacts[:x].save!` yourself. Any artifact mutated in memory (`<<`, in-place hash writes) is automatically persisted by the job when the run completes (after `after_complete` callbacks run, so a final aggregate computed there is captured) and when a run is paused or cancelled mid-flight (so in-progress output is never lost). Reads alone never create a record. `artifacts.save(name, value)` already wrote immediately, so it never depends on auto-flush; you can also call `save!` explicitly on an accumulator artifact for intermediate checkpoints.

**Metadata:** every artifact records lightweight stats on save -- entry/line count, byte size, and a generated-at timestamp -- shown on the run page (`12 entries · 3.4 KB · 2 minutes ago`) without loading the full payload. Available on the model via `artifact.summary`, `artifact.byte_size`, and `artifact.generated_at`.

**File artifacts** -- if `file_name` is omitted, it defaults to `task_class_name_YYYYMMDD_HHMMSS`:

```ruby
artifact :export, type: :file
# File name auto-generated: "export_users_20260218_143022"

artifact :report, type: :file, file_name: "report.pdf"
# Explicit file name: "report.pdf"
```

### Callbacks

Hook into the task lifecycle:

```ruby
class ImportUsers < MaintenanceOnSteroids::Task
  after_start :notify_started
  after_complete :notify_completed
  after_error :notify_failed
  after_pause :log_pause
  after_cancel :cleanup
  after_interrupt :save_progress

  def collection
    User.where(imported: false)
  end

  def process(user)
    user.update!(imported: true)
  end

  private

  def notify_started
    Slack.notify("#imports", "User import started")
  end

  def notify_completed
    Slack.notify("#imports", "User import completed!")
  end

  def notify_failed
    Slack.notify("#imports", "User import failed!")
  end

  def log_pause
    Rails.logger.info "Import paused by user"
  end

  def cleanup
    TempFile.cleanup
  end

  def save_progress
    # Called on both pause and cancel, before the specific callback
  end
end
```

**Available callbacks:**

| Callback | When it fires |
|----------|--------------|
| `after_start` | Task begins execution |
| `after_complete` | Task finishes successfully |
| `after_error` | Task raises an exception |
| `after_pause` | Task is paused |
| `after_cancel` | Task is cancelled |
| `after_interrupt` | Task is interrupted (fires before pause or cancel) |

### Job Configuration

Set a custom queue and/or priority:

```ruby
class HeavyExport < MaintenanceOnSteroids::Task
  job do
    queue "exports"
    priority 10
  end

  def call
    # ...
  end
end
```

### Database Role Switching

To scan a collection against a replica, declare the role. The job holds it open
for the whole scan:

```ruby
class BackfillTask < MaintenanceOnSteroids::Task
  job do
    database_role :reading   # :read is accepted too
  end

  def collection
    User.where(active: true)   # every batch query runs on the replica
  end

  def process(user)
    user.update!(...)          # writes run on the primary
  end
end
```

`process` and the run's own cursor/progress bookkeeping step back to `:writing`
automatically, so a declared read role never blocks the task's writes.

For a one-off read inside `call` or `process`, `with_database_role` wraps a
block:

```ruby
def call
  stale = with_database_role(:read) { User.where(active: false).count }
  artifacts.save(:summary, { stale: stale })
end
```

> **The block must force whatever it reads.** Returning a lazy `Relation` from
> `with_database_role` does nothing — the role is restored on the way out and
> the query runs later, on the primary. That is why `collection` uses the
> declarative `database_role` above instead.

## Configuration

`rails g maintenance_on_steroids:install` writes
`config/initializers/maintenance_on_steroids.rb` for you, with every access
control commented out and ready to fill in. The full set of options:

```ruby
MaintenanceOnSteroids.configure do |config|
  # --- Authentication ---

  # HTTP Basic auth (simplest option)
  config.http_basic_authentication_enabled   = true
  config.http_basic_authentication_user_name = "admin"
  config.http_basic_authentication_password  = Rails.application.credentials.maintenance_password

  # Or use a custom authentication hook (e.g. Devise)
  config.authentication = -> {
    authenticate_user!  # Devise method
  }

  # Role-based access control
  config.verify_access_proc = ->(controller) {
    controller.current_user&.admin?
  }

  # --- User Tracking ---

  # Track who triggers each run
  config.current_user_resolver = -> {
    Current.user  # Or any way to get the current user
  }

  # Customize how user names are displayed
  config.user_display_formatter = ->(run) {
    User.find(run.user_id).full_name rescue run.user_email
  }
end
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `parent_controller` | `"ActionController::Base"` | Base controller class for the engine |
| `max_upload_size` | `50.megabytes` | Maximum size (bytes) for file inputs uploaded when starting a run |
| `max_artifact_size` | `64.megabytes` | Hard ceiling on a single stored artifact; exceeding it fails the run |
| `http_basic_authentication_enabled` | `false` | Enable HTTP Basic auth |
| `http_basic_authentication_user_name` | `"admin"` | HTTP Basic username |
| `http_basic_authentication_password` | `"secret"` | HTTP Basic password |
| `authentication` | `nil` | Proc executed in controller context for auth |
| `verify_access_proc` | `nil` | Proc receiving controller, return true/false |
| `current_user_resolver` | `nil` | Proc returning the current user object |
| `user_display_formatter` | `nil` | Proc receiving Run, returning display string |
| `allow_insecure_dashboard` | `false` | Boot in production with no access-control layer configured |

### Authentication & Access Control

The dashboard is mounted in **your** app, so it inherits your app's middleware — but it ships with **no access control of its own until you configure it**. Three independent layers run as `before_action`s on every engine request, in order. Use any combination; each layer is skipped when its config is left at the default.

| Order | Layer | Config | When it runs | On failure |
|-------|-------|--------|--------------|------------|
| 1 | **HTTP Basic** | `http_basic_authentication_enabled` | Always (when enabled) | `401 Unauthorized` (browser credential prompt) |
| 2 | **Auth hook** | `authentication` | After Basic passes | Whatever the proc does (usually `redirect_to` sign-in) |
| 3 | **Access check** | `verify_access_proc` | After the hook | `403 Forbidden` (`"Access denied"`) |

> [!WARNING]
> **In production the engine refuses to boot until one layer is configured.** With none of them set, anyone who can reach the mounted path can run, pause, and cancel maintenance tasks against your database.
>
> The shipped HTTP Basic defaults (`admin` / `secret`) are **placeholders**, and leaving the password at `"secret"` counts as *unconfigured* — a dashboard behind a published password is not protected, and treating it as configured would make the most dangerous setup the quietest one. Override it, and prefer HTTPS since Basic credentials travel in every request.
>
> If the dashboard is already gated somewhere this gem cannot see — a reverse proxy, a VPN, your own middleware — say so explicitly rather than leaving the layers empty:
>
> ```ruby
> config.allow_insecure_dashboard = true
> ```
>
> Outside production, an unconfigured dashboard logs a warning instead of raising.

#### Recipe: HTTP Basic (quickest)

Good for a staging box or a small team. Credentials are compared in constant time (`ActiveSupport::SecurityUtils.secure_compare`), so it's not vulnerable to timing attacks.

```ruby
# config/initializers/maintenance_on_steroids.rb
MaintenanceOnSteroids.configure do |config|
  config.http_basic_authentication_enabled   = true
  config.http_basic_authentication_user_name = "admin"
  config.http_basic_authentication_password  = Rails.application.credentials.maintenance_password
end
```

#### Recipe: Devise + admin role (most common)

Reuse your app's existing login, then restrict to admins. Point `parent_controller` at your `ApplicationController` so Devise's helpers (`current_user`, `authenticate_user!`) are in scope.

```ruby
MaintenanceOnSteroids.configure do |config|
  config.parent_controller = "ApplicationController"

  # Layer 2: bounce anyone who isn't signed in
  config.authentication = -> {
    redirect_to(main_app.new_user_session_path, alert: "Please sign in.") unless current_user
  }

  # Layer 3: of the signed-in users, only admins get in (renders 403 otherwise)
  config.verify_access_proc = ->(controller) { controller.current_user&.admin? }

  # Stamp each run with who triggered it (shown in the UI)
  config.current_user_resolver = -> { current_user }
end
```

#### Recipe: IP allowlist

`verify_access_proc` receives the controller, so any request attribute is fair game — e.g. lock the dashboard to your office/VPN range:

```ruby
ALLOWED_IPS = %w[203.0.113.4 198.51.100.0/24].map { |ip| IPAddr.new(ip) }

config.verify_access_proc = ->(controller) {
  ip = IPAddr.new(controller.request.remote_ip)
  ALLOWED_IPS.any? { |range| range.include?(ip) }
}
```

Combine layers freely — e.g. HTTP Basic **and** an IP check both have to pass. Each returns independently, so the first failing layer short-circuits the request.

## Dashboard

The engine provides a full-featured web UI at your mounted path (default: `/maintenance`).

### Pages

- **Dashboard** -- stats overview, active runs, and recent history; runs with output artifacts show a 📎 indicator with the artifact count
- **Tasks** -- all registered task classes, sortable by name (default) or last execution time; each row shows the last run's status and age, and never-executed tasks carry a "New" badge
- **Task detail** -- task metadata, run history, "New Run" and "Source" buttons
- **Source viewer** -- view the Ruby source code of any task class
- **New Run** -- form with typed inputs to start a task
- **Run detail** -- live progress bar, status, duration, estimated time remaining, parameters, artifacts, pause/resume/cancel controls, and a "View Source" shortcut

### Live Progress

Active runs poll for status updates every 2 seconds. The progress bar, percentage, status badge, duration, and the **Estimated (pending)** time remaining (`2d 4h 12m 30s`-style, leading zero units omitted) update in real-time without page refresh.

The dashboard auto-refreshes its stats and active-runs table every 2 seconds in the background (paused while the tab is hidden) -- no flash, no scroll jumps.

While a run is in a transitional state (`pausing`, `cancelling`), the run page shows a visible auto-refresh countdown next to the status badge and reloads every few seconds until the worker settles the state.

### Theme

The UI supports dark and light themes. Click the sun/moon toggle in the top bar. Your preference is saved in localStorage.

## How Resumption Works

This gem uses Rails 8.1's `ActiveJob::Continuable` for safe background processing:

1. **Collection tasks** iterate over records using `find_each`, ordered by primary key
2. After processing each record, the cursor (primary key) is saved both to `ActiveJob::Continuable`'s step and to the database
3. If Sidekiq restarts mid-job, `ActiveJob::Continuable` resumes from its last cursor
4. If you pause and resume, a new job is enqueued that reads the cursor from the database
5. In both cases, the query uses `WHERE id > cursor` to skip already-processed records

**No record is skipped, and only a failed record is retried.** The cursor advances only *after* `process` returns, so an interruption or a pause replays nothing already done, while a record that raised is retried on the next resume (at-least-once for that record). The suite verifies this across Sidekiq restarts, pause/resume cycles, and multiple interruptions.

Artifacts buffered in memory are flushed on every exit path -- completion, pause, cancel, error, and worker interruption -- so a deploy mid-run never silently truncates a CSV or log artifact.

> **Note:** cursor-based resumption relies on monotonically increasing primary keys. Collections with UUID/string primary keys can skip or repeat records on resume -- the job logs a warning when it detects one.

## Operations

### Recovering from worker crashes

If a worker process dies hard (OOM kill, `kill -9`, node failure), its run can be left in `running` forever. `Run.reap_stale!` transitions in-flight runs whose row hasn't been touched recently to `errored` (the job updates the row at least once per processed record, so `updated_at` acts as a heartbeat):

```ruby
# Run periodically (cron, recurring job, e.g. solid_queue recurring task):
MaintenanceOnSteroids::Run.reap_stale!(threshold: 30.minutes)
```

Pick a threshold comfortably larger than the time your slowest task needs to process a single record. `enqueued` and `paused` runs are never reaped -- and a run interrupted by `ActiveJob::Continuable` is moved back to `enqueued` before its job is re-queued, so a backed-up queue can never get it reaped out from under the worker.

### Recovering from a failed run

A run that raises is marked `errored` and stops, with the message and backtrace on the run page. Because the cursor was persisted after each successful record, you can fix the cause and hit **Resume**: the run picks up from the record that failed and reprocesses nothing before it. Resuming clears the stored error.

### Pruning old runs

Nothing expires runs on its own, so a long-lived app keeps every run, backtrace
and stored artifact forever. `Run.prune!` deletes finished runs (and their
artifacts) past a cutoff; schedule it like `reap_stale!`:

```ruby
MaintenanceOnSteroids::Run.prune!(older_than: 90.days)
```

Only `completed`, `cancelled` and `errored` runs are eligible — anything active
or paused is left alone regardless of age. Returns the number deleted.

### Artifact size limits

**Artifacts are buffered in the worker's memory and stored in a single database
row.** That makes them ideal for maintenance *results* — a summary, a log, a
few thousand rows of exceptions — and unsuitable as a bulk-export pipeline.
A million-row CSV will exhaust the worker before it ever reaches the database.

`MaintenanceOnSteroids.max_artifact_size` (default 64 MB) turns that into a
clear failure instead of an OOM kill: exceeding it fails the run with a message
naming the artifact. For genuinely large output, write to object storage from
the task and keep only a reference:

```ruby
def process(record)
  # ... build rows ...
end

after_complete do
  key = S3Uploader.call(big_file)
  artifacts.save(:location, { bucket: "exports", key: key })
end
```

Inline previews on the run page are separately capped (256 KB, or 200 top-level
entries for JSON documents) so viewing a large artifact can't take down the web
process. The full payload is still available via Download for file and CSV
artifacts.

### Pausing a long-running callable task

Collection tasks check for a pending pause or cancel between records. A callable
task is a single unit of work, so a long `call` won't notice Pause until it
returns. Call `checkpoint!` at the points where stopping is safe:

```ruby
def call
  Account.find_each do |account|
    checkpoint!          # honours a pending Pause/Cancel here
    account.recalculate!
  end
end
```

When a stop is pending, `checkpoint!` does not return — the job unwinds, buffered
artifacts are flushed, and the run lands in `paused` or `cancelled`.

### Preventing concurrent runs

Nothing stops an operator from starting the same task twice — a double-clicked
**New Run** on a destructive task runs it twice. Declare a limit:

```ruby
class BackfillTask < MaintenanceOnSteroids::Task
  job do
    concurrency 1
  end
end
```

Further runs are refused while that many are still active. The check is advisory
(two simultaneous submissions can still race); it exists to catch the double-click,
not to provide a distributed lock. For a hard guarantee, take an advisory lock
inside the task itself.

### Content Security Policy

The dashboard's live updates use small inline `<script>` blocks and no build
step, so a strict CSP without `'unsafe-inline'` will block polling (the pages
still render and work; they just stop refreshing themselves). If your app sets
a strict policy, scope an exception to the mounted path:

```ruby
# config/initializers/content_security_policy.rb
Rails.application.config.content_security_policy_nonce_directives = %w[script-src]
```

or exclude the engine's path from the policy entirely.

### Collections with UUID or string primary keys

Resumption works by remembering the last processed primary key and continuing
with `WHERE id > cursor`, which assumes keys increase over time. That holds for
integer and bigint keys, and for time-ordered UUIDs (UUIDv7, ULID). It does
**not** hold for random UUIDv4: after an interruption such a run can skip
records it never processed and reprocess others.

The job logs a warning when it detects a non-integer primary key. If your
collection uses random UUIDs, either avoid pause/resume for it or scope the
collection so each run is complete in itself.

### Running on SQLite

A running task writes to the runs table after every processed record, so the dashboard's own writes (pause, cancel, resume) compete with the worker for SQLite's single writer. Make sure your `database.yml` sets a busy timeout, or those clicks will fail with `SQLite3::BusyException: database is locked`:

```yaml
production:
  adapter: sqlite3
  database: storage/production.sqlite3
  timeout: 5000    # ms to wait for the write lock instead of failing instantly
```

The default is `0` -- no waiting at all. Postgres and MySQL need no equivalent setting.

## Instrumentation

Every run lifecycle transition emits an `ActiveSupport::Notifications` event in the `maintenance_on_steroids` namespace -- the same pattern as the `maintenance_tasks` gem:

```ruby
ActiveSupport::Notifications.subscribe("enqueued.maintenance_on_steroids") do |event|
  run = event.payload[:run]
  Rails.logger.info "Enqueued #{event.payload[:task_name]} (run ##{run.id})"
end

# Or subscribe to all events at once:
ActiveSupport::Notifications.subscribe(/\.maintenance_on_steroids\z/) do |event|
  StatsD.increment("maintenance.#{event.name.split('.').first}")
end
```

| Event | Fired when |
|-------|-----------|
| `enqueued.maintenance_on_steroids` | A run is enqueued (initial enqueue and re-enqueue on resume) |
| `started.maintenance_on_steroids` | The job starts executing for the first time (not on resumptions/retries) |
| `paused.maintenance_on_steroids` | A pause request is honored by the worker |
| `resumed.maintenance_on_steroids` | A paused run is resumed |
| `cancelled.maintenance_on_steroids` | A run is cancelled (directly, or honored by the worker mid-run) |
| `succeeded.maintenance_on_steroids` | A run completes successfully |
| `errored.maintenance_on_steroids` | A run raises -- payload includes `error:` with the exception |

Payload: `{ run:, task_name: }` (plus `error:` for `errored`).

## Development

### Setup

```bash
git clone https://github.com/igorkasyanchuk/maintenance_on_steroids.git
cd maintenance_on_steroids
bundle install
```

### Run the dummy app

```bash
cd spec/dummy
bin/rails db:schema:load
bin/rails db:seed
bin/rails server
```

Visit `http://localhost:3000/maintenance` to see the dashboard. The seed creates 12 users with different roles for testing.

### Run tests

```bash
bundle exec rspec
```

### Project structure

```
app/
  controllers/maintenance_on_steroids/
    application_controller.rb    # Auth chain
    dashboard_controller.rb      # Dashboard page
    jobs_controller.rb           # Task list, detail, source
    runs_controller.rb           # Run CRUD, pause/resume/cancel, status API
  models/maintenance_on_steroids/
    run.rb                       # Run record (status, progress, user tracking)
    artifact.rb                  # Artifact record (jsonb, blob, text)
  views/maintenance_on_steroids/
    dashboard/index.html.erb     # Dashboard
    jobs/index.html.erb          # Task list
    jobs/show.html.erb           # Task detail
    jobs/source.html.erb         # Source code viewer
    runs/new.html.erb            # New run form
    runs/show.html.erb           # Run detail with live progress
  jobs/maintenance_on_steroids/
    run_job.rb                   # ActiveJob::Continuable job
lib/
  maintenance_on_steroids/
    task.rb                      # Base task class
    form_dsl.rb                  # Form input DSL
    artifact_dsl.rb              # Artifact DSL
    about_dsl.rb                 # Task metadata DSL
    job_dsl.rb                   # Queue configuration DSL
    callbacks_dsl.rb             # Lifecycle callbacks DSL
    params_proxy.rb              # Typed parameter access
    artifacts_proxy.rb           # Artifact read/write
    jsonb_artifact.rb            # Hash-like JSONB wrapper
    job_registry.rb              # Task class discovery
    engine.rb                    # Rails engine setup
  generators/maintenance_on_steroids/
    install/                     # Install generator
    job/                         # Task generator
```

## Full Example

A complete task using most features:

```ruby
class MigrateUserProfiles < MaintenanceOnSteroids::Task
  about do
    title "Migrate User Profiles"
    description "Migrates legacy profile data to the new format"
    owner "Backend Team"
  end

  job do
    queue "maintenance"
  end

  form do
    input :batch_label, type: :string, default: "migration-v2", help_text: "Label for tracking"
    input :dry_run, type: :boolean, default: true, help_text: "Preview changes without saving"
  end

  artifact :results, type: :jsonb, default: {}
  artifact :error_log, type: :file, file_name: "migration_errors.csv"

  after_start :log_start
  after_complete :send_summary
  after_error :alert_team

  def collection
    User.where(profile_version: 1)
  end

  def process(user)
    new_data = ProfileMigrator.transform(user.profile_data)

    if params[:dry_run]
      artifacts[:results][user.id.to_s] = { status: "preview", changes: new_data }
    else
      user.update!(profile_data: new_data, profile_version: 2)
      artifacts[:results][user.id.to_s] = { status: "migrated" }
    end
    artifacts[:results].save!
  end

  private

  def log_start
    Rails.logger.info "[MigrateUserProfiles] Started: #{params[:batch_label]}"
  end

  def send_summary
    count = artifacts[:results].size
    AdminMailer.migration_complete(count, params[:batch_label]).deliver_later
  end

  def alert_team
    Slack.notify("#alerts", "Profile migration failed! Check run ##{run.id}")
  end
end
```

## Alternatives

https://github.com/Shopify/maintenance_tasks - a gem from Shopify. This gem actually inspired me to build my version, because the gem from Shopify is missing many features I need.

## License

MIT License. See [LICENSE.txt](LICENSE.txt).
