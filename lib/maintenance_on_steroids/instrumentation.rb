module MaintenanceOnSteroids
  # Emits ActiveSupport::Notifications events for run lifecycle transitions.
  #
  #   ActiveSupport::Notifications.subscribe("enqueued.maintenance_on_steroids") do |event|
  #     run = event.payload[:run]
  #     Rails.logger.info "Enqueued #{event.payload[:task_name]} (run ##{run.id})"
  #   end
  #
  # Events: enqueued, started, paused, resumed, cancelled, succeeded, errored.
  # Payload: { run:, task_name: } plus { error: } for errored.
  module Instrumentation
    NAMESPACE = "maintenance_on_steroids"

    def self.instrument(event, run, extra = {})
      ActiveSupport::Notifications.instrument(
        "#{event}.#{NAMESPACE}",
        { run: run, task_name: run.task_class }.merge(extra)
      )
    end

    # Best-effort instrumentation: AS::Notifications re-raises subscriber
    # exceptions, so every lifecycle call routes through here. A raising
    # subscriber must never affect run outcomes (corrupt status, 500 a
    # controller, trigger a retry storm) -- the error is logged and swallowed.
    # See docs/solutions/runtime-errors/unguarded-instrumentation-corrupts-run-status-2026-06-15.md
    def self.safe_instrument(event, run, extra = {})
      instrument(event, run, extra)
    rescue => e
      Rails.logger.error "[MaintenanceOnSteroids] Instrumentation error (#{event}): " \
                         "#{e.class}: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}"
    end
  end
end
