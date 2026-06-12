# Maintenance on Steroids

A powerful maintenance task runner for **Rails 8.1+** that leverages `ActiveJob::Continuable` for safe, resumable background processing. Think of it as a batteries-included toolkit for one-off data migrations, batch updates, CSV exports, and any maintenance work your app needs.

**Built-in web dashboard** with dark/light themes, live progress tracking, pause/resume/cancel controls, source code viewer, and artifact downloads.

## Features

- **Collection & callable tasks** -- iterate over ActiveRecord relations or run one-off jobs
- **Automatic resumption** -- cursor-based progress tracking survives Sidekiq restarts and pause/resume cycles without reprocessing records
- **Rich DSL** -- typed form inputs, named artifacts, lifecycle callbacks, queue configuration, task metadata
- **Live dashboard** -- real-time progress bars, status badges, run history, and source code viewer
- **Artifacts** -- store JSON results, export CSV/binary files, downloadable from the UI
- **Pause / Resume / Cancel** -- safely interrupt long-running tasks mid-execution
- **User tracking** -- records who triggered each run with configurable display
- **Authentication** -- HTTP Basic, Devise integration, custom access procs
- **Dark & light themes** -- toggle with one click, persisted in localStorage

## Requirements

- Ruby >= 3.2
- Rails >= 8.1 (uses `ActiveJob::Continuable`)

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
| `:file` | Binary blob | CSV exports, PDFs, images |
| `:text` | Text column | Plain text output |

**JSONB artifacts** behave like a hash:

```ruby
artifact :result, type: :jsonb, default: {}

def process(user)
  user.update!(active: false)
  artifacts[:result][user.id.to_s] = { deactivated: true }
  artifacts[:result].save!
end
```

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

Set a custom queue:

```ruby
class HeavyExport < MaintenanceOnSteroids::Task
  job do
    queue "exports"
  end

  def call
    # ...
  end
end
```

### Database Role Switching

Read from a replica:

```ruby
def collection
  with_database_role(:read) { User.where(active: true) }
end
```

## Configuration

Create an initializer at `config/initializers/maintenance_on_steroids.rb`:

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
| `tasks_module` | `nil` | Module where task classes are defined |
| `http_basic_authentication_enabled` | `false` | Enable HTTP Basic auth |
| `http_basic_authentication_user_name` | `"admin"` | HTTP Basic username |
| `http_basic_authentication_password` | `"secret"` | HTTP Basic password |
| `authentication` | `nil` | Proc executed in controller context for auth |
| `verify_access_proc` | `nil` | Proc receiving controller, return true/false |
| `current_user_resolver` | `nil` | Proc returning the current user object |
| `user_display_formatter` | `nil` | Proc receiving Run, returning display string |

### Authentication Chain

Authentication runs in this order:

1. **HTTP Basic** -- if enabled, prompts for credentials
2. **Authentication hook** -- custom auth (e.g. `authenticate_user!`)
3. **Access verification** -- role-based check, returns 403 if denied

### Devise Integration Example

```ruby
# config/initializers/maintenance_on_steroids.rb
MaintenanceOnSteroids.configure do |config|
  config.parent_controller = "ApplicationController"

  config.authentication = -> {
    unless current_user
      redirect_to main_app.new_user_session_path, alert: "Please sign in."
    end
  }

  config.verify_access_proc = ->(controller) {
    controller.current_user&.role == "admin"
  }

  config.current_user_resolver = -> { current_user }
end
```

## Dashboard

The engine provides a full-featured web UI at your mounted path (default: `/maintenance`).

### Pages

- **Dashboard** -- stats overview, active runs, recent history, task list
- **Tasks** -- all registered task classes
- **Task detail** -- task metadata, run history, "New Run" and "Source" buttons
- **Source viewer** -- view the Ruby source code of any task class
- **New Run** -- form with typed inputs to start a task
- **Run detail** -- live progress bar, status, duration, parameters, artifacts, pause/resume/cancel controls

### Live Progress

Active runs poll for status updates every 2 seconds. The progress bar, percentage, status badge, and duration update in real-time without page refresh.

### Theme

The UI supports dark and light themes. Click the sun/moon toggle in the top bar. Your preference is saved in localStorage.

## How Resumption Works

This gem uses Rails 8.1's `ActiveJob::Continuable` for safe background processing:

1. **Collection tasks** iterate over records using `find_each`, ordered by primary key
2. After processing each record, the cursor (primary key) is saved both to `ActiveJob::Continuable`'s step and to the database
3. If Sidekiq restarts mid-job, `ActiveJob::Continuable` resumes from its last cursor
4. If you pause and resume, a new job is enqueued that reads the cursor from the database
5. In both cases, the query uses `WHERE id > cursor` to skip already-processed records

**Records are never processed twice.** The gem includes tests that verify this behavior across Sidekiq restarts, pause/resume cycles, and multiple interruptions.

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

## License

MIT License. See [LICENSE.txt](LICENSE.txt).
