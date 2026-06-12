module MaintenanceOnSteroids
  class JobsController < ApplicationController
    def index
      @task_classes = MaintenanceOnSteroids.task_classes
    end

    def show
      @task_class = MaintenanceOnSteroids::JobRegistry.find(params[:id])
      @runs = MaintenanceOnSteroids::Run.where(task_class: params[:id]).recent.limit(50)
    end

    def source
      @task_class = MaintenanceOnSteroids::JobRegistry.find(params[:id])
      @source_file, @source_line = Object.const_source_location(@task_class.name)
      @source_code = if @source_file && File.exist?(@source_file)
        File.read(@source_file)
      end
    end
  end
end
