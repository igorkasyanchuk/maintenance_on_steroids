require "rails_helper"

RSpec.describe "Jobs", type: :request do
  describe "GET /maintenance/jobs" do
    it "returns success" do
      get "/maintenance/jobs"
      expect(response).to have_http_status(:success)
    end

    it "lists all registered tasks" do
      get "/maintenance/jobs"
      expect(response.body).to include("UpdateUsersTask")
      expect(response.body).to include("Update Users")
    end
  end

  describe "GET /maintenance/jobs/:id" do
    it "returns success" do
      get "/maintenance/jobs/UpdateUsersTask"
      expect(response).to have_http_status(:success)
    end

    it "shows task details" do
      get "/maintenance/jobs/UpdateUsersTask"
      expect(response.body).to include("Update Users")
      expect(response.body).to include("Updates age for users matching a name")
    end

    it "lists runs for the task" do
      MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "completed")
      get "/maintenance/jobs/UpdateUsersTask"
      expect(response.body).to include("completed")
    end
  end

  describe "GET /maintenance/jobs/:id/source" do
    it "returns success" do
      get "/maintenance/jobs/UpdateUsersTask/source"
      expect(response).to have_http_status(:success)
    end

    it "displays the source code" do
      get "/maintenance/jobs/UpdateUsersTask/source"
      expect(response.body).to include("def collection")
      expect(response.body).to include("def process(user)")
    end

    it "shows the file path" do
      get "/maintenance/jobs/UpdateUsersTask/source"
      expect(response.body).to include("update_users_task.rb")
    end
  end
end
