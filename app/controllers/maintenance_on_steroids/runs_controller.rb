module MaintenanceOnSteroids
  class RunsController < ApplicationController
    before_action :set_run, only: %i[show pause resume cancel status artifact_download]

    def new
      @task_class = MaintenanceOnSteroids::JobRegistry.find(params[:job_id])
    end

    def create
      @task_class = MaintenanceOnSteroids::JobRegistry.find(params[:job_id])

      run = MaintenanceOnSteroids::Run.new(
        task_class: params[:job_id],
        status: "enqueued",
        params: extract_scalar_params,
        progress_current: 0,
        progress_total: 0
      )

      run.record_user!(resolve_current_user)

      if run.save
        store_file_params(run)
        run.enqueue!
        redirect_to run_path(run), notice: "Task enqueued successfully."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def show
      @task_class_obj = MaintenanceOnSteroids::JobRegistry.find(@run.task_class)
    end

    def pause
      @run.pause!
      redirect_to run_path(@run), notice: "Task pause requested."
    end

    def resume
      @run.resume!
      redirect_to run_path(@run), notice: "Task resumed."
    end

    def cancel
      @run.cancel!
      redirect_to run_path(@run), notice: "Task cancelled."
    end

    # JSON endpoint for progress polling
    def status
      render json: {
        status: @run.status,
        progress_current: @run.progress_current,
        progress_total: @run.progress_total,
        progress_percentage: @run.progress_percentage,
        formatted_duration: @run.formatted_duration,
        error_message: @run.error_message
      }
    end

    def artifact_download
      artifact = @run.artifacts.find(params[:artifact_id])
      send_data artifact.data_blob,
                filename: artifact.file_name || "#{artifact.name}.bin",
                type: artifact.content_type || "application/octet-stream",
                disposition: "attachment"
    end

    private

    def set_run
      @run = MaintenanceOnSteroids::Run.find(params[:id])
    end

    def extract_scalar_params
      task_class = MaintenanceOnSteroids::JobRegistry.find(params[:job_id])
      scalar_inputs = task_class.form_inputs.reject(&:blob?)

      result = {}
      scalar_inputs.each do |input|
        value = params.dig(:task_params, input.name)
        result[input.name] = value if value.present?
      end
      result
    end

    def store_file_params(run)
      task_class = MaintenanceOnSteroids::JobRegistry.find(params[:job_id])
      blob_inputs = task_class.form_inputs.select(&:blob?)

      blob_inputs.each do |input|
        file = params.dig(:task_params, input.name)
        next unless file.respond_to?(:read)

        run.artifacts.create!(
          name: input.name.to_s,
          kind: "input",
          artifact_type: "blob",
          data_blob: file.read,
          file_name: file.original_filename,
          content_type: file.content_type
        )
      end
    end
  end
end
