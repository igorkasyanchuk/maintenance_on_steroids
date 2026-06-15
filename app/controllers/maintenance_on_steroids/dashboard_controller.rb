module MaintenanceOnSteroids
  class DashboardController < ApplicationController
    def index
      @task_classes = MaintenanceOnSteroids.task_classes
      @active_runs = Run.active.recent.limit(25)
      @recent_runs = Run.recent.limit(25)
      run_ids = @active_runs.map(&:id) | @recent_runs.map(&:id)
      @artifact_counts = Artifact.where(run_id: run_ids, kind: "output").group(:run_id).count
      status_counts = Run.group(:status).count
      @stats = {
        total_tasks: @task_classes.size,
        active_runs: status_counts.values_at(*Run::ACTIVE_STATUSES).compact.sum,
        completed: status_counts.fetch("completed", 0),
        errored: status_counts.fetch("errored", 0)
      }
    end
  end
end
