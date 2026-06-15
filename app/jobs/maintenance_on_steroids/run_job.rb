module MaintenanceOnSteroids
  class RunJob < ActiveJob::Base
    include ActiveJob::Continuable

    # Allow configuring queue via the task's job DSL
    # The queue is set dynamically when enqueuing

    def perform(run_id)
      @run = MaintenanceOnSteroids::Run.find(run_id)
      @task = @run.task_class.constantize.new(@run)

      # Guard against duplicate execution: terminal runs (including errored
      # runs re-delivered by adapter-level retries) must not restart.
      return if @run.cancelled? || @run.completed? || @run.errored?

      # Don't clobber a pause/cancel requested while the job was waiting in
      # the queue (e.g. after a Continuable interruption) -- check_status!
      # will honor it. after_start callbacks fire only on the first start,
      # not on resumptions or retries.
      unless @run.pausing? || @run.cancelling?
        first_start = @run.started_at.nil?
        @run.update!(status: "running", started_at: @run.started_at || Time.current)
        if first_start
          safe_instrument(:started, @run)
          safe_callback { @task.run_start_callbacks }
        end
      end

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

        complete_run!
      end
    rescue => e
      @run&.update!(
        status: "errored",
        error_message: e.message,
        error_backtrace: e.backtrace&.first(50)&.join("\n"),
        completed_at: Time.current
      )
      safe_instrument(:errored, @run, error: e) if @run
      safe_callback { @task&.run_error_callbacks }
      flush_artifacts!
      raise
    end

    private

    def process_collection
      step :process_collection do |step|
        @collection ||= @task.collection
        warn_about_non_integer_primary_key(@collection)

        if @run.progress_total.zero?
          total = @collection.count
          @run.update!(progress_total: total)
        end

        # The DB cursor (@run.cursor) is authoritative: it is written after
        # every processed record and *before* step.set!, so it is always at
        # least as advanced as the step cursor serialized with the job.
        # step.cursor only matters when the DB cursor is absent.
        effective_cursor = @run.cursor.presence || step.cursor

        scope = if effective_cursor
                  @collection.unscope(:order).where(@collection.model.arel_table[@collection.model.primary_key].gt(effective_cursor))
                else
                  @collection.unscope(:order)
                end

        scope.order(@collection.model.primary_key => :asc).find_each do |record|
          check_status!

          @task.process(record)
          cursor_value = record.public_send(record.class.primary_key)
          advance_progress!(cursor_value)
          # Record the last processed pk as an exclusive cursor (resume uses gt(cursor)),
          # matching @run.cursor semantics. advance! would store pk+1 and skip a record.
          step.set!(cursor_value)
        end
      end
    end

    # Atomic SQL increment: avoids read-modify-write lost updates and keeps
    # the in-memory model in sync without an extra SELECT.
    def advance_progress!(cursor_value)
      @run.class.where(id: @run.id).update_all(
        ["progress_current = progress_current + 1, cursor = ?, updated_at = ?", cursor_value.to_s, Time.current]
      )
      @run.progress_current += 1
      @run.cursor = cursor_value.to_s
    end

    # Compare-and-set completion: only a run still in "running" may complete.
    # If an operator issued pause/cancel after the last per-record check,
    # honor it instead of overwriting with "completed".
    def complete_run!
      completed = @run.class.where(id: @run.id, status: "running").update_all(
        status: "completed",
        completed_at: Time.current,
        updated_at: Time.current
      ) == 1

      @run.reload

      if completed
        safe_instrument(:succeeded, @run)
        safe_callback { @task.run_complete_callbacks }
        # Flush AFTER callbacks so any final aggregate they compute persists.
        flush_artifacts!
      else
        check_status!
      end
    end

    def warn_about_non_integer_primary_key(collection)
      return if @pk_checked

      @pk_checked = true
      model = collection.model
      pk_type = model.columns_hash[model.primary_key.to_s]&.type
      return if pk_type == :integer

      Rails.logger.warn(
        "[MaintenanceOnSteroids] #{@run.task_class}: collection primary key " \
        "#{model.primary_key.inspect} has type #{pk_type.inspect}. Cursor-based " \
        "resumption relies on monotonically increasing primary keys; " \
        "UUID/string keys can skip or repeat records on resume."
      )
    end

    def check_status!
      @run.reload

      case @run.status
      when "pausing"
        safe_callback { @task.run_interrupt_callbacks }
        @run.update!(status: "paused")
        safe_instrument(:paused, @run)
        safe_callback { @task.run_pause_callbacks }
        # Persist work-in-progress buffers so a pause/resume doesn't lose them.
        flush_artifacts!
        throw :abort_run
      when "cancelling"
        safe_callback { @task.run_interrupt_callbacks }
        @run.update!(status: "cancelled", completed_at: Time.current)
        safe_instrument(:cancelled, @run)
        safe_callback { @task.run_cancel_callbacks }
        flush_artifacts!
        throw :abort_run
      end
    end

    def safe_callback
      yield
    rescue => e
      Rails.logger.error "[MaintenanceOnSteroids] Callback error: #{e.message}"
    end

    # ActiveSupport::Notifications re-raises subscriber exceptions. Without
    # this guard a raising subscriber would propagate into the rescue block
    # and overwrite an already-terminal run as errored (or trigger a retry
    # storm for :started). Instrumentation must never affect run outcomes.
    def safe_instrument(event, run, extra = {})
      MaintenanceOnSteroids::Instrumentation.instrument(event, run, extra)
    rescue => e
      Rails.logger.error "[MaintenanceOnSteroids] Instrumentation error (#{event}): " \
                         "#{e.class}: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}"
    end

    # Auto-persists any artifact the task wrote in memory but didn't explicitly
    # save. Dirty-only, so reads never create phantom rows. Never raises.
    def flush_artifacts!
      @task&.artifacts&.flush!
    rescue => e
      Rails.logger.error "[MaintenanceOnSteroids] Artifact flush error: #{e.class}: #{e.message}"
    end
  end
end
