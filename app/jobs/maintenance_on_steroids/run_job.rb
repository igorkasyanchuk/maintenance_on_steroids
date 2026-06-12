module MaintenanceOnSteroids
  class RunJob < ActiveJob::Base
    include ActiveJob::Continuable

    # Allow configuring queue via the task's job DSL
    # The queue is set dynamically when enqueuing

    def perform(run_id)
      @run = MaintenanceOnSteroids::Run.find(run_id)
      @task = @run.task_class.constantize.new(@run)

      return if @run.cancelled? || @run.completed?

      @run.update!(status: "running", started_at: @run.started_at || Time.current)
      safe_callback { @task.run_start_callbacks }

      catch(:abort_run) do
        if @task.collection_task?
          process_collection
        elsif @task.callable_task?
          step :execute do |_step|
            check_status!
            @task.call
          end
        else
          raise "Task #{@run.task_class} must define either collection+process or call"
        end

        @run.update!(status: "completed", completed_at: Time.current)
        safe_callback { @task.run_complete_callbacks }
      end
    rescue => e
      @run&.update!(
        status: "errored",
        error_message: e.message,
        error_backtrace: e.backtrace&.first(50)&.join("\n"),
        completed_at: Time.current
      )
      safe_callback { @task&.run_error_callbacks }
      raise
    end

    private

    def process_collection
      step :process_collection do |step|
        collection = @task.collection

        if @run.progress_total.zero?
          total = collection.count
          @run.update!(progress_total: total)
        end

        # Use step.cursor (from ActiveJob::Continuable, e.g. Sidekiq restart)
        # or fall back to @run.cursor (persisted in DB, e.g. pause/resume)
        effective_cursor = step.cursor || @run.cursor

        scope = if effective_cursor
                  collection.unscope(:order).where(collection.model.arel_table[collection.model.primary_key].gt(effective_cursor))
                else
                  collection.unscope(:order)
                end

        scope.order(collection.model.primary_key => :asc).find_each do |record|
          check_status!

          @task.process(record)
          cursor_value = record.public_send(record.class.primary_key)
          @run.update!(progress_current: @run.progress_current + 1, cursor: cursor_value.to_s)
          step.advance! from: cursor_value
        end
      end
    end

    def check_status!
      @run.reload

      case @run.status
      when "pausing"
        safe_callback { @task.run_interrupt_callbacks }
        @run.update!(status: "paused")
        safe_callback { @task.run_pause_callbacks }
        throw :abort_run
      when "cancelling"
        safe_callback { @task.run_interrupt_callbacks }
        @run.update!(status: "cancelled", completed_at: Time.current)
        safe_callback { @task.run_cancel_callbacks }
        throw :abort_run
      end
    end

    def safe_callback
      yield
    rescue => e
      Rails.logger.error "[MaintenanceOnSteroids] Callback error: #{e.message}"
    end
  end
end
