require "rails_helper"

RSpec.describe "Runs", type: :request do
  describe "GET /maintenance/jobs/:job_id/runs/new" do
    it "returns success" do
      get "/maintenance/jobs/UpdateUsersTask/runs/new"
      expect(response).to have_http_status(:success)
    end

    it "renders form inputs" do
      get "/maintenance/jobs/UpdateUsersTask/runs/new"
      expect(response.body).to include("Name")
      expect(response.body).to include("Age")
    end

    it "works for tasks without inputs" do
      get "/maintenance/jobs/SimpleCallableTask/runs/new"
      expect(response).to have_http_status(:success)
      expect(response.body).to include("no input parameters")
    end

    it "404s for task names that are not registered tasks" do
      expect {
        get "/maintenance/jobs/User/runs/new"
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "POST /maintenance/jobs/:job_id/runs" do
    it "creates a run and redirects" do
      expect {
        post "/maintenance/jobs/UpdateUsersTask/runs", params: {
          task_params: { name: "Alice", age: "30" }
        }
      }.to change(MaintenanceOnSteroids::Run, :count).by(1)

      run = MaintenanceOnSteroids::Run.last
      expect(run.task_class).to eq("UpdateUsersTask")
      expect(run.status).to eq("enqueued")
      expect(run.params).to eq({ "name" => "Alice", "age" => "30" })
      expect(response).to redirect_to("/maintenance/runs/#{run.id}")
    end

    it "creates a run for tasks without params" do
      expect {
        post "/maintenance/jobs/SimpleCallableTask/runs"
      }.to change(MaintenanceOnSteroids::Run, :count).by(1)
    end

    it "rejects submissions missing required params with 422" do
      expect {
        post "/maintenance/jobs/UpdateUsersTask/runs", params: {
          task_params: { name: "", age: "" }
        }
      }.not_to change(MaintenanceOnSteroids::Run, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Missing required parameters")
    end

    it "renders new with 422 when the run cannot be saved" do
      allow_any_instance_of(MaintenanceOnSteroids::Run).to receive(:save).and_return(false)

      post "/maintenance/jobs/SimpleCallableTask/runs"

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "marks the run errored when enqueueing fails" do
      allow_any_instance_of(MaintenanceOnSteroids::Run).to receive(:enqueue!).and_raise("queue down")

      post "/maintenance/jobs/UpdateUsersTask/runs", params: {
        task_params: { name: "Alice", age: "30" }
      }

      run = MaintenanceOnSteroids::Run.last
      expect(run.status).to eq("errored")
      expect(run.error_message).to include("queue down")
      expect(response).to redirect_to("/maintenance/runs/#{run.id}")
      expect(flash[:alert]).to include("could not be enqueued")
    end

    it "404s for task names that are not registered tasks" do
      expect {
        post "/maintenance/jobs/NotARealTask/runs"
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "GET /maintenance/runs/:id" do
    let(:run) do
      MaintenanceOnSteroids::Run.create!(
        task_class: "UpdateUsersTask",
        status: "running",
        progress_current: 5,
        progress_total: 10,
        started_at: 1.minute.ago
      )
    end

    it "returns success" do
      get "/maintenance/runs/#{run.id}"
      expect(response).to have_http_status(:success)
    end

    it "shows progress" do
      get "/maintenance/runs/#{run.id}"
      expect(response.body).to include("5 / 10")
      expect(response.body).to include("50.0%")
    end

    it "shows pause button for running jobs" do
      get "/maintenance/runs/#{run.id}"
      expect(response.body).to include("Pause")
    end

    it "shows polling script for active jobs" do
      get "/maintenance/runs/#{run.id}"
      expect(response.body).to include("setInterval")
    end

    it "renders runs whose task class no longer exists" do
      orphan = MaintenanceOnSteroids::Run.create!(task_class: "DeletedOldTask", status: "completed")
      get "/maintenance/runs/#{orphan.id}"
      expect(response).to have_http_status(:success)
      expect(response.body).to include("DeletedOldTask")
    end
  end

  describe "POST /maintenance/runs/:id/pause" do
    it "pauses a running run" do
      run = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "running")
      post "/maintenance/runs/#{run.id}/pause"
      expect(run.reload.status).to eq("pausing")
      expect(response).to redirect_to("/maintenance/runs/#{run.id}")
      expect(flash[:notice]).to be_present
    end

    it "shows an alert when the run cannot be paused" do
      run = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "completed")
      post "/maintenance/runs/#{run.id}/pause"
      expect(run.reload.status).to eq("completed")
      expect(flash[:alert]).to include("cannot be paused")
    end
  end

  describe "POST /maintenance/runs/:id/resume" do
    it "resumes a paused run" do
      run = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "paused")
      post "/maintenance/runs/#{run.id}/resume"
      expect(run.reload.status).to eq("enqueued")
      expect(response).to redirect_to("/maintenance/runs/#{run.id}")
    end

    it "shows an alert when the run is not paused" do
      run = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "running")
      post "/maintenance/runs/#{run.id}/resume"
      expect(run.reload.status).to eq("running")
      expect(flash[:alert]).to include("cannot be resumed")
    end
  end

  describe "POST /maintenance/runs/:id/cancel" do
    it "cancels an enqueued run" do
      run = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "enqueued")
      post "/maintenance/runs/#{run.id}/cancel"
      expect(run.reload.status).to eq("cancelled")
    end

    it "sets cancelling for running run" do
      run = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "running")
      post "/maintenance/runs/#{run.id}/cancel"
      expect(run.reload.status).to eq("cancelling")
    end
  end

  describe "GET /maintenance/runs/:id/status" do
    it "returns JSON status" do
      run = MaintenanceOnSteroids::Run.create!(
        task_class: "UpdateUsersTask",
        status: "running",
        progress_current: 3,
        progress_total: 10,
        started_at: 30.seconds.ago
      )
      get "/maintenance/runs/#{run.id}/status"
      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("running")
      expect(json["progress_current"]).to eq(3)
      expect(json["progress_total"]).to eq(10)
      expect(json["progress_percentage"]).to eq(30.0)
    end
  end

  describe "GET /maintenance/runs/:id/artifacts/:artifact_id/download" do
    it "downloads blob artifacts" do
      run = MaintenanceOnSteroids::Run.create!(task_class: "CsvExportTask", status: "completed")
      artifact = run.artifacts.create!(
        name: "csv_file",
        kind: "output",
        artifact_type: "blob",
        data_blob: "id,name\n1,Alice",
        file_name: "export.csv",
        content_type: "text/csv"
      )

      get "/maintenance/runs/#{run.id}/artifacts/#{artifact.id}/download"
      expect(response).to have_http_status(:success)
      expect(response.body).to eq("id,name\n1,Alice")
    end
  end
end
