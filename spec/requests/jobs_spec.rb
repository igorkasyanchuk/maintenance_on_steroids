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

    it "paginates the run history" do
      55.times { MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "completed") }

      get "/maintenance/jobs/UpdateUsersTask"
      expect(response.body).to include("Page 1 of 2")
      expect(response.body.scan(/<tr>/).size).to be <= 51 # 50 rows + header

      get "/maintenance/jobs/UpdateUsersTask", params: { page: 2 }
      expect(response.body).to include("Page 2 of 2")
    end

    it "clamps out-of-range page params" do
      55.times { MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "completed") }

      get "/maintenance/jobs/UpdateUsersTask", params: { page: 0 }
      expect(response.body).to include("Page 1 of 2")

      get "/maintenance/jobs/UpdateUsersTask", params: { page: 9999 }
      expect(response.body).to include("Page 2 of 2") # clamped to last page
    end

    it "shows an artifact-count badge for runs with output artifacts" do
      run = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "completed")
      run.artifacts.create!(name: "result", kind: "output", artifact_type: "jsonb", data_jsonb: { "a" => 1 })

      get "/maintenance/jobs/UpdateUsersTask"
      expect(response.body).to include("&#128206;") # paperclip badge
    end

    it "omits the artifact badge for runs without output artifacts" do
      MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "completed")
      get "/maintenance/jobs/UpdateUsersTask"
      expect(response.body).not_to include("&#128206;")
    end
  end

  describe "GET /maintenance/jobs auto-refresh gating" do
    it "renders the auto-refresh poller only when a task is active" do
      get "/maintenance/jobs"
      expect(response.body).not_to include("setInterval")

      MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "running")
      get "/maintenance/jobs"
      expect(response.body).to include("setInterval")
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

    it "pins the highlight.js CDN script with a Subresource Integrity hash" do
      get "/maintenance/jobs/UpdateUsersTask/source"
      # A future template edit that drops the attribute (or a version bump that
      # forgets to recompute the hash) regresses the CDN supply-chain guard.
      expect(response.body).to match(/highlight\.min\.js"\s+integrity="sha384-/)
    end
  end
end

RSpec.describe "Jobs list ordering", type: :request do
  # sort_by is not stable, so tasks sharing a sort key used to swap places
  # between page loads.
  let!(:twins) do
    a = Class.new(MaintenanceOnSteroids::Task) do
      about { title "Same Title" }
      def call; end
    end
    b = Class.new(MaintenanceOnSteroids::Task) do
      about { title "same title" }
      def call; end
    end
    stub_const("ZebraTask", a)
    stub_const("AardvarkTask", b)
    [a, b].each { |k| MaintenanceOnSteroids::JobRegistry.register(k) }
    [a, b]
  end

  it "orders tasks with the same title deterministically across requests" do
    bodies = 3.times.map { get("/maintenance/jobs"); response.body }

    orders = bodies.map { |b| [b.index("AardvarkTask"), b.index("ZebraTask")] }
    expect(orders.uniq.size).to eq(1)
    # Class name breaks the tie, so the alphabetically first one wins.
    expect(orders.first.first).to be < orders.first.last
  end

  it "orders never-executed tasks deterministically under sort=last_run" do
    bodies = 3.times.map { get("/maintenance/jobs", params: { sort: "last_run" }); response.body }

    expect(bodies.map { |b| b.index("AardvarkTask") <=> b.index("ZebraTask") }.uniq.size).to eq(1)
  end
end
