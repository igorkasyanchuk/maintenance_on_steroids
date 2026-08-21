module MaintenanceOnSteroids
  class RunJob < ActiveJob::Base
    include ActiveJob::Continuable

    # The run row is the record of truth. If it was deleted there is nothing
    # left to do, and retrying only produces a RecordNotFound storm in the
    # queue -- ~21 failing attempts over a day for work that can never succeed.
    discard_on ActiveRecord::RecordNotFound

    # Continuable would otherwise silently re-enqueue a job that raised after
    # the continuation advanced. This gem surfaces errors to an operator
    # instead: #perform marks the run "errored" and stops, and the operator
    # resumes it from the dashboard (Run#resumable? includes "errored").
    # Left on, that hidden retry fires against an already-terminal run and
    # no-ops, so the run looks retried but never advances.
    self.resume_errors_after_advancing = false

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
            with_collection_role { @task.call }
          end
        else
          raise "Task #{@run.task_class} must define either collection+process or call"
        end

        complete_run!
      end
    rescue ActiveJob::Continuation::Interrupt
      # Continuable is about to re-enqueue this job. Leaving the row in
      # "running" freezes its updated_at heartbeat, so Run.reap_stale! would
      # mistake a queued run for a dead worker and mark it errored. CAS on
      # "running" so a pause/cancel requested in the meantime is not clobbered.
      Run.where(id: @run.id, status: "running")
         .update_all(status: "enqueued", updated_at: Time.current) if @run
      raise
    rescue => e
      @run&.update!(
        status: "errored",
        error_message: e.message,
        error_backtrace: e.backtrace&.first(50)&.join("\n"),
        completed_at: Time.current
      )
      safe_instrument(:errored, @run, error: e) if @run
      safe_callback { @task&.run_error_callbacks }
      raise
    ensure
      # Single flush point for every exit path -- completion, pause, cancel,
      # error, and (critically) ActiveJob::Continuation::Interrupt, which
      # subclasses Exception and so is invisible to `rescue => e`. Without it a
      # SIGTERM mid-run discards every buffered artifact row while the cursor
      # keeps advancing, and the run still reports "completed".
      # flush! is dirty-only and never raises, so re-entry here is a no-op.
      flush_artifacts!
    end

    private

    def process_collection
      step :process_collection do |step|
        @collection ||= with_collection_role { @task.collection }
        warn_about_non_integer_primary_key(@collection)

        if @run.progress_total.zero?
          total = with_collection_role { @collection.count }
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

        # The role wraps the whole scan, so every batch query hits the replica.
        # Each record's work steps back to :writing -- process may write, and
        # the run's own cursor/progress bookkeeping always does.
        with_collection_role do
          scope.order(@collection.model.primary_key => :asc).find_each do |record|
            with_writing_role do
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
      end
    end

    # Both are pass-throughs unless the task declared `job { database_role ... }`,
    # so the default path pays nothing for connection switching.
    def with_collection_role(&block)
      role = @task.class.job_config.database_role
      return yield unless role

      ActiveRecord::Base.connected_to(role: role, &block)
    end

    def with_writing_role(&block)
      return yield unless @task.class.job_config.database_role

      ActiveRecord::Base.connected_to(role: :writing, &block)
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
        throw :abort_run
      when "cancelling"
        safe_callback { @task.run_interrupt_callbacks }
        @run.update!(status: "cancelled", completed_at: Time.current)
        safe_instrument(:cancelled, @run)
        safe_callback { @task.run_cancel_callbacks }
        throw :abort_run
      end
    end

    def safe_callback
      yield
    rescue => e
      Rails.logger.error "[MaintenanceOnSteroids] Callback error: #{e.message}"
    end

    def safe_instrument(event, run, extra = {})
      MaintenanceOnSteroids::Instrumentation.safe_instrument(event, run, extra)
    end

    # Auto-persists any artifact the task wrote in memory but didn't explicitly
    # save. Dirty-only, so reads never create phantom rows, and re-running it
    # after a save is a no-op. Never raises -- it runs from perform's ensure,
    # where an exception would mask the real one.
    def flush_artifacts!
      @task&.artifacts&.flush!
    rescue => e
      Rails.logger.error "[MaintenanceOnSteroids] Artifact flush error: #{e.class}: #{e.message}"
    end
  end
end
