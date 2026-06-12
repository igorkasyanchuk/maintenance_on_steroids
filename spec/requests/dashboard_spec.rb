require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  describe "GET /maintenance" do
    it "returns success" do
      get "/maintenance"
      expect(response).to have_http_status(:success)
    end

    it "shows stats" do
      MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "completed")
      MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "errored")
      get "/maintenance"
      expect(response.body).to include("Available Tasks")
      expect(response.body).to include("Active Runs")
      expect(response.body).to include("Completed")
      expect(response.body).to include("Errored")
    end

    it "shows active runs" do
      run = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "running", progress_current: 5, progress_total: 10)
      get "/maintenance"
      expect(response.body).to include("Active Runs")
      expect(response.body).to include("##{run.id}")
    end

    it "shows recent history" do
      run = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "completed")
      get "/maintenance"
      expect(response.body).to include("Recent History")
      expect(response.body).to include("##{run.id}")
    end

    it "shows available tasks" do
      get "/maintenance"
      expect(response.body).to include("UpdateUsersTask")
    end

    it "shows runs for deleted task classes" do
      run = MaintenanceOnSteroids::Run.create!(task_class: "DeletedOldTask", status: "completed")
      get "/maintenance"
      expect(response.body).to include("DeletedOldTask")
      expect(response.body).to include("##{run.id}")
    end
  end
end
