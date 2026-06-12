module MaintenanceOnSteroids
  class JobsController < ApplicationController
    before_action :set_task_class, only: %i[show source]

    def index
      @task_classes = MaintenanceOnSteroids.task_classes
      @active_run_counts = MaintenanceOnSteroids::Run.active.group(:task_class).count
    end

    def show
      @runs = MaintenanceOnSteroids::Run.where(task_class: @task_class.name).recent.limit(50)
    end

    def source
      @source_file, @source_line = Object.const_source_location(@task_class.name)
      @source_code =
        if @source_file && @source_file.start_with?(Rails.root.to_s) && File.exist?(@source_file)
          File.read(@source_file)
        end
    end

    private

    # JobRegistry.find only resolves registered Task subclasses; anything
    # else (arbitrary user-supplied constants) returns nil -> 404.
    def set_task_class
      @task_class = MaintenanceOnSteroids::JobRegistry.find(params[:id])
      raise ActiveRecord::RecordNotFound, "Unknown task: #{params[:id]}" unless @task_class
    end
  end
end
