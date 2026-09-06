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
    attr_writer :enqueue_failure_backtrace

    # Continuable dispatches retries itself, bypassing Run#enqueue!. Preserve a
    # visible, resumable failure if that dispatch is refused or the queue is down.
    def enqueue(...)
      result = super
      record_dispatch_failure!(enqueue_error || EnqueueFailed.new("Enqueue callback aborted the job")) unless result
      result
    rescue => e
      record_dispatch_failure!(e)
      raise
    end

    def perform(run_id)
      @run = Run.find(run_id)
      return unless claim_run!

      @task = @run.task_instance
      @database_role = @task.class.job_config.database_role
      @task.checkpoint_handler = method(:task_checkpoint!)

      catch(:abort_run) do
        if @first_start
          safe_instrument(:started, @run)
          safe_callback { @task.run_start_callbacks }
        end
        check_status!
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
    rescue ExecutionLost
      # A reaper or newer attempt owns the row. Never flush this worker's cache.
      nil
    rescue ActiveJob::Continuation::Interrupt
      begin
        @run.with_execution_lock do
          flush_artifacts!
          @run.update!(status: @run.running? ? "enqueued" : @run.status, execution_token: nil)
        end
      rescue ExecutionLost
        return
      rescue => e
        record_error!(e)
        raise e
      end
      raise
    rescue => e
      record_error!(e)
      raise
    end

    private

    def record_dispatch_failure!(error)
      return unless arguments.first

      Run.where(id: arguments.first, active_job_id: job_id, execution_token: nil,
                status: %w[enqueued pausing cancelling]).update_all(
        status: "errored", error_message: "Failed to enqueue: #{error.message}",
        error_backtrace: @enqueue_failure_backtrace,
        completed_at: Time.current, updated_at: Time.current
      )
    end

    def claim_run!
      @run.with_lock do
        return false unless @run.execution_token.nil?
        return false unless %w[enqueued pausing cancelling].include?(@run.status)
        return false if @run.active_job_id && @run.active_job_id != job_id

        @run.worker_token = SecureRandom.uuid
        @first_start = @run.enqueued? && @run.started_at.nil?
        attributes = { execution_token: @run.worker_token, active_job_id: job_id }
        if @run.enqueued?
          attributes.merge!(status: "running", started_at: @run.started_at || Time.current)
        end
        @run.update!(attributes)
      end
      true
    end

    def record_error!(error)
      return unless @run&.worker_token

      @run.with_execution_lock do
        safe_callback { @task&.run_error_callbacks }
        # Cleanup must not replace the original task error. A flush error on
        # the normal completion path reaches here as the primary exception.
        begin
          flush_artifacts!
        rescue => flush_error
          Rails.logger.error "[MaintenanceOnSteroids] Artifact cleanup error: #{flush_error.message}"
        end
        @run.update!(status: "errored", execution_token: nil,
                     error_message: error.message,
                     error_backtrace: error.backtrace&.first(50)&.join("\n"),
                     completed_at: Time.current)
      end
      safe_instrument(:errored, @run, error: error)
    rescue ExecutionLost
      nil
    end

    def process_collection
      step :process_collection do |step|
        @collection ||= with_collection_role { @task.collection }
        warn_about_non_integer_primary_key(@collection)

        if @run.progress_total.zero?
          total = with_collection_role { @collection.count }
          @run.with_execution_lock { @run.update!(progress_total: total) }
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

              checkpointed = false
              begin
                @processing_record = true
                @task.process(record)
                cursor_value = record.public_send(record.class.primary_key)
                # A crash commits both output and cursor, or neither. Host task
                # side effects still need idempotency (they may use other DBs/APIs).
                @run.with_execution_lock do
                  flush_artifacts!
                  advance_progress!(cursor_value)
                end
                checkpointed = true
              ensure
                @processing_record = false
                # A failed record must not leak buffered rows into error cleanup.
                @task.artifacts.discard! unless checkpointed
              end
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
      return yield unless @database_role

      ActiveRecord::Base.connected_to(role: @database_role, &block)
    end

    def with_writing_role(&block)
      return yield unless @database_role

      ActiveRecord::Base.connected_to(role: :writing, &block)
    end

    # Called while holding the execution lock and the output transaction.
    def advance_progress!(cursor_value)
      @run.update!(progress_current: @run.progress_current + 1, cursor: cursor_value.to_s)
    end

    def complete_run!
      completed = false
      @run.with_execution_lock do
        if @run.running?
          # Commit callback output and completion together. An operator waiting
          # on this short finalization lock will then see the final state.
          safe_callback { @task.run_complete_callbacks }
          flush_artifacts!
          @run.reload
          if @run.running?
            @run.update!(status: "completed", completed_at: Time.current, execution_token: nil)
            completed = true
          end
        end
      end
      if completed
        safe_instrument(:succeeded, @run)
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

    def task_checkpoint!
      if @processing_record
        # Do not persist partial record output without its cursor. Collection
        # pause/cancel takes effect at the next record boundary.
        @run.with_execution_lock { @run.touch }
      else
        check_status!
      end
    end

    def check_status!
      event = nil
      @run.with_execution_lock do
        case @run.status
        when "pausing", "cancelling"
          safe_callback { @task.run_interrupt_callbacks }
          # Re-read in case a callback requested cancellation instead of pause.
          @run.reload
          event = @run.cancelling? ? :cancelled : :paused
          safe_callback { event == :paused ? @task.run_pause_callbacks : @task.run_cancel_callbacks }
          flush_artifacts!
          @run.update!(status: event.to_s, execution_token: nil,
                       completed_at: event == :cancelled ? Time.current : nil)
        else
          # Callable checkpoints are a real heartbeat and persist their output.
          # Collection output is committed only alongside its record cursor.
          flush_artifacts! unless @task.collection_task?
          @run.touch
        end
      end
      if event
        safe_instrument(event, @run)
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

    def flush_artifacts!
      @task&.artifacts&.flush!
    end
  end
end
