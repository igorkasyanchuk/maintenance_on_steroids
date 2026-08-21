module MaintenanceOnSteroids
  class JobsController < ApplicationController
    before_action :set_task_class, only: %i[show source]

    def index
      @task_classes = MaintenanceOnSteroids.task_classes
      @active_run_counts = MaintenanceOnSteroids::Run.active.group(:task_class).count
      # Fetch only the latest run per task_class (MAX(id) per group), avoiding
      # loading every historical run. Works on both SQLite and Postgres.
      names = @task_classes.map(&:name)
      @last_runs = MaintenanceOnSteroids::Run
                   .where(id: MaintenanceOnSteroids::Run.where(task_class: names).group(:task_class).select("MAX(id)"))
                   .index_by(&:task_class)
      @sort = params[:sort] == "last_run" ? "last_run" : "name"
      # Class name is the tiebreaker in both orders. sort_by is not stable, so
      # without it two tasks sharing a title -- or any two never-executed tasks,
      # which all share the same epoch timestamp -- swap places between page
      # loads for no reason.
      @task_classes =
        if @sort == "last_run"
          # Most recently executed first; never-executed tasks at the bottom.
          @task_classes.sort_by { |tc| [-(@last_runs[tc.name]&.created_at.to_i || 0), tc.name.to_s] }
        else
          @task_classes.sort_by { |tc| [tc.task_title.to_s.downcase, tc.name.to_s] }
        end
    end

    def show
      @per_page = 50
      scope = MaintenanceOnSteroids::Run.where(task_class: @task_class.name)
      @total_runs = scope.count
      @total_pages = [(@total_runs.to_f / @per_page).ceil, 1].max
      # Clamp both ends so ?page=0/-1 and ?page=99999 don't render dead pages
      # or trigger huge offset scans.
      @page = params[:page].to_i.clamp(1, @total_pages)
      @runs = scope.recent.limit(@per_page).offset((@page - 1) * @per_page)
      @artifact_counts = MaintenanceOnSteroids::Artifact
                         .where(run_id: @runs.map(&:id), kind: "output")
                         .group(:run_id).count
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
