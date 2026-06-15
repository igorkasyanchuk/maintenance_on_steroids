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

    it "sorts tasks by title by default" do
      get "/maintenance/jobs"
      titles = MaintenanceOnSteroids.task_classes.map { |tc| tc.task_title.to_s }.sort_by(&:downcase)
      positions = titles.map { |t| response.body.index(t) }
      expect(positions).not_to include(nil)
      expect(positions).to eq(positions.sort)
    end

    it "sorts by last execution time when sort=last_run" do
      MaintenanceOnSteroids::Run.create!(task_class: "SummarizeUsersTask", status: "completed", created_at: 1.hour.ago)
      MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "completed", created_at: 1.minute.ago)

      get "/maintenance/jobs", params: { sort: "last_run" }
      expect(response.body.index("UpdateUsersTask")).to be < response.body.index("SummarizeUsersTask")
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

  describe "GET /maintenance/jobs/:id for unknown or non-task constants" do
    it "404s for unknown class names" do
      expect {
        get "/maintenance/jobs/TotallyUnknownTask"
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "404s for real constants that are not maintenance tasks" do
      expect {
        get "/maintenance/jobs/User"
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "404s on source for real constants that are not maintenance tasks" do
      expect {
        get "/maintenance/jobs/File/source"
      }.to raise_error(ActiveRecord::RecordNotFound)
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
