module MaintenanceOnSteroids
  class Run < ApplicationRecord
    has_many :artifacts, dependent: :destroy

    STATUSES = %w[enqueued running pausing paused cancelling cancelled completed errored].freeze

    validates :task_class, presence: true
    validates :status, inclusion: { in: STATUSES }

    scope :recent, -> { order(created_at: :desc) }
    scope :active, -> { where(status: %w[enqueued running pausing paused]) }

    STATUSES.each do |s|
      define_method(:"#{s}?") { status == s }
    end

    def active?
      %w[enqueued running pausing paused].include?(status)
    end

    def stoppable?
      %w[running pausing].include?(status)
    end

    def pausable?
      status == "running"
    end

    def resumable?
      status == "paused"
    end

    def cancellable?
      %w[enqueued running pausing paused].include?(status)
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

    def task_instance
      @task_instance ||= task_class.constantize.new(self)
    end

    def enqueue!
      job_config = task_instance.class.job_config
      job = RunJob.new(id)
      job.queue_name = job_config.queue_name if job_config.queue_name
      job.enqueue
      update!(active_job_id: job.job_id)
    end

    def pause!
      update!(status: "pausing") if running?
    end

    def resume!
      return unless paused?
      update!(status: "enqueued")
      enqueue!
    end

    def cancel!
      if enqueued? || paused?
        update!(status: "cancelled", completed_at: Time.current)
      elsif running?
        update!(status: "cancelling")
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

    def resolve_current_user
      resolver = MaintenanceOnSteroids.current_user_resolver
      resolver&.call
    rescue => e
      Rails.logger.debug "[MaintenanceOnSteroids] Could not resolve current user: #{e.message}"
      nil
    end
  end
end
