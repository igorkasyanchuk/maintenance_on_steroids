module MaintenanceOnSteroids
  class DashboardController < ApplicationController
    def index
      @task_classes = MaintenanceOnSteroids.task_classes
      @active_runs = Run.active.recent
      @recent_runs = Run.recent.limit(25)
      @stats = {
        total_tasks: @task_classes.size,
        active_runs: @active_runs.size,
        completed: Run.where(status: "completed").count,
        errored: Run.where(status: "errored").count
      }
    end
  end
end
