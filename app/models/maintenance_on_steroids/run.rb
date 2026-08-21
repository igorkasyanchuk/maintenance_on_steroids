module MaintenanceOnSteroids
  class Run < ApplicationRecord
    has_many :artifacts, dependent: :destroy

    STATUSES = %w[enqueued running pausing paused cancelling cancelled completed errored].freeze
    ACTIVE_STATUSES = %w[enqueued running pausing paused].freeze
    # Statuses an operator may restart from. "errored" is included because a
    # run that died on one bad record has already advanced its cursor -- the
    # resumed job picks up after it rather than redoing the work.
    RESUMABLE_STATUSES = %w[paused errored].freeze
    # Statuses that mean "a worker currently holds this run" -- candidates
    # for staleness reaping when the worker died without updating the row.
    STALE_CANDIDATE_STATUSES = %w[running pausing cancelling].freeze
    # Runs that will never change again, and so are safe to prune.
    TERMINAL_STATUSES = %w[completed cancelled errored].freeze

    validates :task_class, presence: true
    validates :status, inclusion: { in: STATUSES }

    scope :recent, -> { order(created_at: :desc, id: :desc) }
    scope :active, -> { where(status: ACTIVE_STATUSES) }

    STATUSES.each do |s|
      define_method(:"#{s}?") { status == s }
    end

    # Transitions runs stuck in an in-flight status to "errored" when the row
    # hasn't been touched for `threshold`. RunJob updates the row at least
    # once per processed record, so updated_at acts as a heartbeat. Call this
    # periodically (cron, recurring job) to recover from worker crashes.
    # Returns the number of reaped runs.
    def self.reap_stale!(threshold: 30.minutes)
      where(status: STALE_CANDIDATE_STATUSES)
        .where(updated_at: ...threshold.ago)
        .update_all(
          status: "errored",
          error_message: "Run marked as stale: no progress for over #{threshold.inspect}. The worker likely crashed.",
          completed_at: Time.current,
          updated_at: Time.current
        )
    end

    # Deletes finished runs older than `older_than`, with their artifacts.
    # Nothing expires these rows on its own, so a long-lived app accumulates
    # every run, backtrace and stored blob forever. Call this periodically the
    # same way as reap_stale!:
    #
    #   MaintenanceOnSteroids::Run.prune!(older_than: 90.days)
    #
    # Only terminal runs are eligible -- anything still active or paused is
    # left alone regardless of age. Returns the number of runs deleted.
    def self.prune!(older_than: 90.days, statuses: TERMINAL_STATUSES)
      scope = where(status: Array(statuses) & TERMINAL_STATUSES)
              .where(created_at: ...older_than.ago)

      # destroy_all rather than delete_all so dependent artifacts go too;
      # batched so pruning a large backlog doesn't build one huge transaction.
      deleted = 0
      scope.in_batches(of: 500) do |batch|
        deleted += batch.destroy_all.size
      end
      deleted
    end

    def active?
      ACTIVE_STATUSES.include?(status)
    end

    def stoppable?
      %w[running pausing].include?(status)
    end

    def pausable?
      status == "running"
    end

    def resumable?
      RESUMABLE_STATUSES.include?(status)
    end

    def cancellable?
      ACTIVE_STATUSES.include?(status)
    end

    def progress_percentage
      return 0 if progress_total.zero?
      [(progress_current.to_f / progress_total * 100).round(1), 100.0].min
    end

    def duration
      return nil unless started_at
      end_time = completed_at || Time.current
      end_time - started_at
    end

    def formatted_duration
      return "—" unless duration
      seconds = duration.to_i
      if seconds < 60
        "#{seconds}s"
      elsif seconds < 3600
        "#{seconds / 60}m #{seconds % 60}s"
      else
        "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
      end
    end

    # Estimated time remaining for the pending records, extrapolated from the
    # current processing rate. Only meaningful while progress is being tracked.
    def estimated_duration
      return nil unless running? && started_at && progress_total.positive? && progress_current.positive?
      # No estimate once we've reached (or overshot) the total -- nothing
      # pending, and progress_current > progress_total would go negative.
      return nil unless progress_current < progress_total
      duration * (progress_total - progress_current) / progress_current
    end

    def formatted_estimated_duration
      total = estimated_duration
      return nil unless total

      total = total.round
      days = total / 86_400
      hours = (total % 86_400) / 3600
      mins = (total % 3600) / 60
      secs = total % 60

      parts = []
      parts << "#{days}d" if days.positive?
      parts << "#{hours}h" if hours.positive? || days.positive?
      parts << "#{mins}m" if mins.positive? || hours.positive? || days.positive?
      parts << "#{secs}s"
      parts.join(" ")
    end

    def task_instance
      @task_instance ||= task_class.constantize.new(self)
    end

    def enqueue!
      job_config = task_instance.class.job_config
      job = RunJob.new(id)
      job.queue_name = job_config.queue_name if job_config.queue_name
      job.priority = job_config.priority if job_config.priority
      job.enqueue
      update!(active_job_id: job.job_id)
      safe_instrument(:enqueued)
    end

    # Compare-and-set, like #resume!: a check-then-update would let a pause
    # clicked as the job finishes overwrite "completed" with "pausing", which
    # nothing but reap_stale! would ever clear.
    # Returns true when the transition was performed, false otherwise.
    def pause!
      claimed = self.class.where(id: id, status: "running").update_all(
        status: "pausing",
        updated_at: Time.current
      ) == 1
      reload if claimed
      claimed
    end

    # Compare-and-set so two concurrent resumes can't both enqueue a job
    # for the same run. Returns true when this call won the transition.
    # Raises EnqueueFailed if the job could not be queued.
    def resume!
      claimed = self.class.where(id: id, status: RESUMABLE_STATUSES).update_all(
        status: "enqueued",
        active_job_id: nil,
        updated_at: Time.current
      ) == 1
      return false unless claimed

      reload
      begin
        enqueue!
      rescue => e
        # The CAS above already left "paused"/"errored", so a failure here
        # (queue backend down, task class deleted) would strand the run in
        # "enqueued" with no job behind it. Put it back in a terminal state
        # the operator can act on, keeping error_backtrace so the original
        # failure is still on the page.
        update!(
          status: "errored",
          error_message: "Failed to enqueue: #{e.message}",
          completed_at: Time.current
        )
        raise EnqueueFailed, e.message
      end

      # Cleared only now that the run is really on its way again -- doing it in
      # the CAS above would destroy the original error before we know whether
      # the resume even succeeds.
      update_columns(completed_at: nil, error_message: nil, error_backtrace: nil)
      safe_instrument(:resumed)
      true
    end

    # Returns true when the transition was performed, false otherwise.
    # NOTE: an already-enqueued job cannot be portably removed from the queue
    # via Active Job. RunJob#perform guards on terminal statuses, so a job
    # that still fires for a cancelled run is a no-op.
    def cancel!
      # Compare-and-set on each group, for the same reason as #pause!.
      if self.class.where(id: id, status: %w[enqueued paused]).update_all(
           status: "cancelled", completed_at: Time.current, updated_at: Time.current
         ) == 1
        reload
        safe_instrument(:cancelled)
        true
      elsif self.class.where(id: id, status: %w[running pausing]).update_all(
              status: "cancelling", updated_at: Time.current
            ) == 1
        reload
        true
      else
        false
      end
    end

    # Store current user who triggered this run.
    # Accepts either a user object directly, or resolves via the configured resolver.
    def record_user!(user = nil)
      user ||= resolve_current_user
      return unless user

      self.user_id = user.id.to_s
      self.user_type = user.class.name
      self.user_email = user.email if user.respond_to?(:email)
    end

    # Formatted user display for the UI.
    # Uses the configured formatter or falls back to a sensible default.
    def user_display
      return nil if user_id.blank?

      if MaintenanceOnSteroids.user_display_formatter
        MaintenanceOnSteroids.user_display_formatter.call(self)
      elsif user_email.present?
        user_email
      else
        "#{user_type}##{user_id}"
      end
    rescue => e
      Rails.logger.debug "[MaintenanceOnSteroids] user_display_formatter error: #{e.message}"
      "#{user_type}##{user_id}"
    end

    def task_title
      klass = task_class.safe_constantize
      klass&.task_title || task_class
    rescue
      task_class
    end

    def task_exists?
      task_class.safe_constantize.present?
    rescue
      false
    end

    def output_artifacts
      artifacts.where(kind: "output")
    end

    def input_artifacts
      artifacts.where(kind: "input")
    end

    private

    def safe_instrument(event, extra = {})
      Instrumentation.safe_instrument(event, self, extra)
    end

    def resolve_current_user
      resolver = MaintenanceOnSteroids.current_user_resolver
      resolver&.call
    rescue => e
      Rails.logger.debug "[MaintenanceOnSteroids] Could not resolve current user: #{e.message}"
      nil
    end
  end
end
