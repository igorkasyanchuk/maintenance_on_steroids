module MaintenanceOnSteroids
  class RunsController < ApplicationController
    before_action :set_run, only: %i[show pause resume cancel artifact_download]
    before_action :set_task_class, only: %i[new create]

    def new
    end

    def create
      missing = missing_required_inputs
      if missing.any?
        flash.now[:alert] = "Missing required parameters: #{missing.map(&:label).join(', ')}."
        return render :new, status: :unprocessable_entity
      end

      oversized = oversized_file_inputs
      if oversized.any?
        max_mb = MaintenanceOnSteroids.max_upload_size / (1024 * 1024)
        flash.now[:alert] = "File too large for: #{oversized.map(&:label).join(', ')} (max #{max_mb} MB)."
        return render :new, status: :unprocessable_entity
      end

      run = MaintenanceOnSteroids::Run.new(
        task_class: @task_class.name,
        status: "enqueued",
        params: extract_scalar_params,
        progress_current: 0,
        progress_total: 0
      )

      run.record_user!(resolve_current_user)

      saved = MaintenanceOnSteroids::Run.transaction do
        if run.save
          store_file_params(run)
          true
        else
          false
        end
      end

      return render :new, status: :unprocessable_entity unless saved

      begin
        run.enqueue!
      rescue => e
        run.update!(status: "errored", error_message: "Failed to enqueue: #{e.message}", completed_at: Time.current)
        return redirect_to run_path(run), alert: "Run could not be enqueued: #{e.message}"
      end

      redirect_to run_path(run), notice: "Task enqueued successfully."
    end

    def show
      # May be nil when the task class no longer exists -- the view falls
      # back to @run.task_title.
      @task_class_obj = MaintenanceOnSteroids::JobRegistry.find(@run.task_class)
    end

    def pause
      if @run.pause!
        redirect_to run_path(@run), notice: "Task pause requested."
      else
        redirect_to run_path(@run), alert: "Task cannot be paused (status: #{@run.status})."
      end
    end

    def resume
      if @run.resume!
        redirect_to run_path(@run), notice: "Task resumed."
      else
        redirect_to run_path(@run), alert: "Task cannot be resumed (status: #{@run.reload.status})."
      end
    end

    def cancel
      if @run.cancel!
        redirect_to run_path(@run), notice: "Task cancelled."
      else
        redirect_to run_path(@run), alert: "Task cannot be cancelled (status: #{@run.status})."
      end
    end

    # JSON endpoint for progress polling -- loads only the rendered columns.
    def status
      run = MaintenanceOnSteroids::Run
              .select(:id, :status, :progress_current, :progress_total, :started_at, :completed_at, :error_message)
              .find(params[:id])

      render json: {
        status: run.status,
        progress_current: run.progress_current,
        progress_total: run.progress_total,
        progress_percentage: run.progress_percentage,
        formatted_duration: run.formatted_duration,
        error_message: run.error_message
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

    # JobRegistry.find only resolves registered Task subclasses; anything
    # else (arbitrary user-supplied constants) returns nil -> 404.
    def set_task_class
      @task_class = MaintenanceOnSteroids::JobRegistry.find(params[:job_id])
      raise ActiveRecord::RecordNotFound, "Unknown task: #{params[:job_id]}" unless @task_class
    end

    def missing_required_inputs
      @task_class.form_inputs.select(&:required).select do |input|
        value = params.dig(:task_params, input.name)
        input.blob? ? !value.respond_to?(:read) : value.blank?
      end
    end

    def oversized_file_inputs
      @task_class.form_inputs.select(&:blob?).select do |input|
        file = params.dig(:task_params, input.name)
        file.respond_to?(:size) && file.size.to_i > MaintenanceOnSteroids.max_upload_size
      end
    end

    def extract_scalar_params
      scalar_inputs = @task_class.form_inputs.reject(&:blob?)

      result = {}
      scalar_inputs.each do |input|
        value = params.dig(:task_params, input.name)
        result[input.name] = value if value.present?
      end
      result
    end

    def store_file_params(run)
      blob_inputs = @task_class.form_inputs.select(&:blob?)

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
