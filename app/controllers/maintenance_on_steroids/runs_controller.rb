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

      invalid = invalid_scalar_inputs
      if invalid.any?
        flash.now[:alert] = "Invalid value for: #{invalid.map(&:label).join(', ')}."
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
    rescue MaintenanceOnSteroids::EnqueueFailed => e
      # Narrow on purpose: Run#resume! already rolled the run back to a terminal
      # status, so show the operator why instead of a 500. Anything else still
      # propagates to the host app's error reporting rather than being
      # mislabelled as an enqueue failure.
      redirect_to run_path(@run), alert: "Run could not be enqueued: #{e.message}"
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
        formatted_estimated_duration: run.formatted_estimated_duration,
        error_message: run.error_message
      }
    end

    def artifact_download
      artifact = @run.artifacts.find(params[:artifact_id])
      # jsonb/text artifacts have no data_blob -- without this the response is
      # a 200 carrying a zero-byte ".bin", which reads as "the task produced
      # nothing" rather than "this artifact isn't a file".
      raise ActiveRecord::RecordNotFound, "Artifact #{artifact.id} is not downloadable" unless artifact.downloadable?

      send_data artifact.data_blob,
                filename: artifact.download_file_name,
                type: artifact.download_content_type,
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

    # The form only constrains the browser -- the posted value is whatever the
    # client sends. Two things are rejected rather than handed to the task:
    # a <select> value outside its declared options, and a nested structure
    # (`task_params[name][x]=1`) where a scalar was declared.
    def invalid_scalar_inputs
      @task_class.form_inputs.reject(&:blob?).select do |input|
        value = params.dig(:task_params, input.name)
        next false if value.nil?
        next true unless scalar_param?(value)

        input.type == :select && input.options.present? &&
          value.present? && input.options.map(&:to_s).exclude?(value.to_s)
      end
    end

    # Rails gives scalars as Strings; anything hash- or array-shaped came from
    # a client building its own payload.
    def scalar_param?(value)
      !value.is_a?(Array) &&
        !value.is_a?(Hash) &&
        !value.is_a?(ActionController::Parameters)
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

        artifact = run.artifacts.new(
          name: input.name.to_s,
          kind: "input",
          artifact_type: "blob",
          data_blob: file.read,
          file_name: file.original_filename,
          content_type: file.content_type
        )
        artifact.refresh_metadata!
        artifact.save!
      end
    end
  end
end
