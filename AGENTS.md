# AGENTS.md — Maintenance on Steroids

## Project Overview

**Maintenance on Steroids** is a Rails Engine (Ruby gem) that provides a batteries-included maintenance task runner for Rails 8.1+ applications. It leverages `ActiveJob::Continuable` for safe, cursor-based, resumable background processing of data migrations, batch updates, CSV exports, and other maintenance work — with a built-in live web dashboard.

**Author:** Igor Kasyanchuk
**License:** MIT
**Ruby:** >= 3.2
**Rails:** >= 8.1

## Architecture

```
maintenance_on_steroids/
├── lib/                              # Gem core
│   ├── maintenance_on_steroids.rb    # Main module, configuration entry point
│   ├── maintenance_on_steroids/
│   │   ├── engine.rb                 # Rails::Engine setup, autoloads app/maintenance
│   │   ├── task.rb                   # Base task class (includes all DSL modules)
│   │   ├── configuration.rb          # Global config registry
│   │   ├── job_registry.rb           # Task class discovery and registration
│   │   ├── form_dsl.rb              # Typed form input builder (8+ input types)
│   │   ├── artifact_dsl.rb          # Artifact definition (jsonb, file, text)
│   │   ├── about_dsl.rb             # Task metadata (title, description, owner)
│   │   ├── job_dsl.rb               # Job configuration (queue, priority)
│   │   ├── callbacks_dsl.rb         # Lifecycle callbacks
│   │   ├── params_proxy.rb          # Typed parameter access with casting
│   │   ├── artifacts_proxy.rb       # Artifact read/write management
│   │   ├── jsonb_artifact.rb        # Hash-like JSONB wrapper
│   │   └── text_artifact.rb         # Text artifact with append/puts
│   └── generators/                   # Rails generators
│       └── maintenance_on_steroids/
│           ├── install/              # Migration, routes mount, app/maintenance dir
│           └── job/                  # Task class scaffolding (collection or callable)
├── app/                              # Engine Rails components
│   ├── controllers/maintenance_on_steroids/
│   │   ├── application_controller.rb # Base controller with 3-step auth chain
│   │   ├── dashboard_controller.rb   # Dashboard stats overview
│   │   ├── jobs_controller.rb        # Task list, detail, source viewer
│   │   └── runs_controller.rb        # Run CRUD, pause/resume/cancel, polling, downloads
│   ├── models/maintenance_on_steroids/
│   │   ├── run.rb                    # Run record: status, progress, cursor, user, timing
│   │   └── artifact.rb              # Artifact record: jsonb, blob, or text data
│   ├── jobs/maintenance_on_steroids/
│   │   └── run_job.rb               # Main job using ActiveJob::Continuable
│   └── views/maintenance_on_steroids/
│       ├── dashboard/               # Dashboard overview
│       ├── jobs/                    # Task list, detail, source viewer
│       └── runs/                    # Run form, detail, live progress
├── config/
│   └── routes.rb                    # Engine route definitions
├── spec/                            # Test suite
│   ├── dummy/                       # Full Rails dummy app for testing
│   ├── jobs/                        # Job specs
│   ├── models/                      # Model specs
│   ├── requests/                    # Integration specs
│   └── lib/                         # Unit specs
└── README.md                        # User-facing documentation
```

## Core Concepts

### Task Types

1. **Collection Tasks** — Iterate over an ActiveRecord relation, processing one record at a time with automatic cursor tracking. Define `collection` and `process(record)` methods.
2. **Callable Tasks** — One-off jobs that run once. Define a `call` method.

### Run Lifecycle

A run transitions through these statuses:
`enqueued` → `running` → `completed`

With interrupt paths:
- `running` → `pausing` → `paused` → `running` (resume)
- `running` → `cancelling` → `cancelled`
- `running` → `errored`

### Cursor-Based Resumption

Collection tasks track a `cursor` (last processed record ID) in the database. When a job is interrupted (Sidekiq restart, pause, etc.), it resumes from the cursor position — no records are reprocessed.

### DSL Modules

Tasks are built using composable DSL blocks:
- `about { title "...", description "...", owner "..." }` — metadata
- `form { input :name, type: :string }` — typed form inputs
- `artifact :name, type: :jsonb` — output artifacts
- `after_start`, `after_complete`, `after_error` — lifecycle callbacks
- `job { queue :low_priority }` — ActiveJob configuration

## Database Schema

Two tables created via migration:

- **`maintenance_on_steroids_runs`** — Tracks each task execution: status, params, cursor, progress, errors, user info, timing.
- **`maintenance_on_steroids_artifacts`** — Stores run outputs: JSONB data, binary blobs, or text content with file metadata.

## Key Patterns

- **Engine namespace:** All classes live under `MaintenanceOnSteroids::`.
- **Host app tasks:** Users place task classes in `app/maintenance/` (autoloaded by the engine).
- **Authentication:** Three-layer chain — HTTP Basic auth → custom auth proc (e.g., Devise) → access verification proc.
- **Frontend:** ERB templates with live dashboard updates, dark/light theme support.
- **Configuration:** Global config via `MaintenanceOnSteroids.configure` block in an initializer.

## Development & Testing

```bash
# Run specs
bundle exec rspec

# Dummy app is at spec/dummy/ for manual testing
cd spec/dummy && bin/rails server
```

The test suite covers cursor resumption, pause/resume/cancel flows, duplicate processing prevention, artifact persistence, and user tracking.

## Conventions

- Follow standard Rails engine patterns.
- Task DSL modules are mixed into `MaintenanceOnSteroids::Task` via `ActiveSupport::Concern`.
- Controllers use engine-scoped routes and authentication.
- Views use partials and setInterval for real-time updates.
