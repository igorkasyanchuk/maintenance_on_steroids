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
  end
end
