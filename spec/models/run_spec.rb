require "rails_helper"

RSpec.describe MaintenanceOnSteroids::Run, type: :model do
  let(:run) do
    MaintenanceOnSteroids::Run.create!(
      task_class: "UpdateUsersTask",
      status: "enqueued",
      params: { name: "Alice", age: 30 }
    )
  end

  describe "validations" do
    it "requires task_class" do
      r = MaintenanceOnSteroids::Run.new(status: "enqueued")
      expect(r).not_to be_valid
      expect(r.errors[:task_class]).to include("can't be blank")
    end

    it "validates status inclusion" do
      r = MaintenanceOnSteroids::Run.new(task_class: "Foo", status: "invalid")
      expect(r).not_to be_valid
      expect(r.errors[:status]).to be_present
    end

    it "allows all valid statuses" do
      MaintenanceOnSteroids::Run::STATUSES.each do |s|
        r = MaintenanceOnSteroids::Run.new(task_class: "Foo", status: s)
        r.valid?
        expect(r.errors[:status]).to be_empty
      end
    end
  end

  describe "status predicates" do
    it "responds to status predicates" do
      run.update!(status: "running")
      expect(run).to be_running
      expect(run).not_to be_paused
    end
  end

  describe "#active?" do
    it "returns true for active statuses" do
      %w[enqueued running pausing paused].each do |s|
        run.update!(status: s)
        expect(run).to be_active
      end
    end

    it "returns false for terminal statuses" do
      %w[completed errored cancelled].each do |s|
        run.update!(status: s)
        expect(run).not_to be_active
      end
    end
  end

  describe "#pausable?" do
    it "is pausable when running" do
      run.update!(status: "running")
      expect(run).to be_pausable
    end

    it "is not pausable when paused" do
      run.update!(status: "paused")
      expect(run).not_to be_pausable
    end
  end

  describe "#resumable?" do
    it "is resumable when paused" do
      run.update!(status: "paused")
      expect(run).to be_resumable
    end
  end

  describe "#cancellable?" do
    it "is cancellable for active statuses" do
      %w[enqueued running pausing paused].each do |s|
        run.update!(status: s)
        expect(run).to be_cancellable
      end
    end
  end

  describe "#progress_percentage" do
    it "returns 0 when total is zero" do
      expect(run.progress_percentage).to eq(0)
    end

    it "calculates percentage" do
      run.update!(progress_current: 50, progress_total: 200)
      expect(run.progress_percentage).to eq(25.0)
    end

    it "caps at 100" do
      run.update!(progress_current: 210, progress_total: 200)
      expect(run.progress_percentage).to eq(100.0)
    end
  end

  describe "#formatted_duration" do
    it "returns dash when not started" do
      expect(run.formatted_duration).to eq("—")
    end

    it "formats seconds" do
      run.update!(started_at: 30.seconds.ago)
      expect(run.formatted_duration).to match(/\d+s/)
    end

    it "formats minutes and seconds" do
      run.update!(started_at: 125.seconds.ago)
      expect(run.formatted_duration).to match(/\d+m \d+s/)
    end

    it "formats hours and minutes" do
      run.update!(started_at: 2.hours.ago - 5.minutes)
      expect(run.formatted_duration).to match(/\d+h \d+m/)
    end
  end

  describe "#formatted_estimated_duration" do
    it "returns nil when not running" do
      expect(run.formatted_estimated_duration).to be_nil
    end

    it "returns nil when no progress yet" do
      run.update!(status: "running", started_at: 1.minute.ago, progress_current: 0, progress_total: 100)
      expect(run.formatted_estimated_duration).to be_nil
    end

    it "shows only seconds for tiny estimates" do
      run.update!(status: "running", started_at: 10.seconds.ago, progress_current: 50, progress_total: 100)
      expect(run.formatted_estimated_duration).to match(/\A\d+s\z/)
    end

    it "shows minutes and seconds when under an hour" do
      run.update!(status: "running", started_at: 10.minutes.ago, progress_current: 50, progress_total: 100)
      expect(run.formatted_estimated_duration).to match(/\A\d+m \d+s\z/)
    end

    it "shows hours, minutes and seconds without days when under a day" do
      run.update!(status: "running", started_at: 2.hours.ago, progress_current: 10, progress_total: 100)
      expect(run.formatted_estimated_duration).to match(/\A\d+h \d+m \d+s\z/)
    end

    it "shows days, hours, minutes and seconds for long estimates" do
      run.update!(status: "running", started_at: 12.hours.ago, progress_current: 10, progress_total: 100)
      expect(run.formatted_estimated_duration).to match(/\A\d+d \d+h \d+m \d+s\z/)
    end

    it "returns nil when progress reaches the total (nothing pending)" do
      run.update!(status: "running", started_at: 1.minute.ago, progress_current: 100, progress_total: 100)
      expect(run.formatted_estimated_duration).to be_nil
    end

    it "returns nil (not a negative estimate) when progress overshoots the total" do
      run.update!(status: "running", started_at: 1.minute.ago, progress_current: 110, progress_total: 100)
      expect(run.estimated_duration).to be_nil
      expect(run.formatted_estimated_duration).to be_nil
    end
  end

  describe "#pause!" do
    it "transitions from running to pausing" do
      run.update!(status: "running")
      run.pause!
      expect(run.reload.status).to eq("pausing")
    end

    it "does nothing if not running" do
      run.update!(status: "paused")
      run.pause!
      expect(run.reload.status).to eq("paused")
    end
  end

  describe "#cancel!" do
    it "transitions enqueued to cancelled" do
      expect(run.cancel!).to be true
      expect(run.reload.status).to eq("cancelled")
      expect(run.completed_at).to be_present
    end

    it "transitions running to cancelling" do
      run.update!(status: "running")
      expect(run.cancel!).to be true
      expect(run.reload.status).to eq("cancelling")
    end

    it "transitions pausing to cancelling" do
      run.update!(status: "pausing")
      expect(run.cancel!).to be true
      expect(run.reload.status).to eq("cancelling")
    end

    it "transitions paused to cancelled" do
      run.update!(status: "paused")
      expect(run.cancel!).to be true
      expect(run.reload.status).to eq("cancelled")
    end

    it "returns false for terminal statuses" do
      run.update!(status: "completed")
      expect(run.cancel!).to be false
      expect(run.reload.status).to eq("completed")
    end
  end

  describe "#pause!" do
    it "returns true when the transition happened" do
      run.update!(status: "running")
      expect(run.pause!).to be true
    end

    it "returns false when not running" do
      run.update!(status: "paused")
      expect(run.pause!).to be false
    end
  end

  describe "#resume!" do
    it "re-enqueues a paused run" do
      run.update!(status: "paused")
      expect(run.resume!).to be true
      expect(run.reload.status).to eq("enqueued")
      expect(run.active_job_id).to be_present
    end

    it "refuses a second resume (compare-and-set)" do
      run.update!(status: "paused")
      stale_copy = MaintenanceOnSteroids::Run.find(run.id)

      expect(run.resume!).to be true
      expect {
        expect(stale_copy.resume!).to be false
      }.not_to have_enqueued_job(MaintenanceOnSteroids::RunJob)

      expect(run.reload.status).to eq("enqueued")
    end

    it "returns false when not paused" do
      run.update!(status: "running")
      expect(run.resume!).to be false
    end
  end

  describe "#enqueue!" do
    it "applies the task's configured queue" do
      run.update!(task_class: "TaskWithQueue")
      run.enqueue!
      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:queue]).to eq("exports")
    end

    it "applies the task's configured priority" do
      priority_task = Class.new(MaintenanceOnSteroids::Task) do
        job do
          priority 7
        end

        def call; end
      end
      stub_const("PriorityTask", priority_task)
      run.update!(task_class: "PriorityTask")

      run.enqueue!
      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:priority]).to eq(7)
    end
  end

  describe ".reap_stale!" do
    it "marks stale in-flight runs as errored" do
      stale = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "running")
      stale.update_column(:updated_at, 2.hours.ago)

      expect(MaintenanceOnSteroids::Run.reap_stale!(threshold: 30.minutes)).to eq(1)

      stale.reload
      expect(stale.status).to eq("errored")
      expect(stale.error_message).to include("stale")
      expect(stale.completed_at).to be_present
    end

    it "leaves fresh running runs alone" do
      fresh = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "running")
      expect(MaintenanceOnSteroids::Run.reap_stale!(threshold: 30.minutes)).to eq(0)
      expect(fresh.reload.status).to eq("running")
    end

    it "does not touch enqueued or paused runs" do
      enqueued = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "enqueued")
      paused = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "paused")
      MaintenanceOnSteroids::Run.where(id: [enqueued.id, paused.id]).update_all(updated_at: 2.hours.ago)

      MaintenanceOnSteroids::Run.reap_stale!(threshold: 30.minutes)

      expect(enqueued.reload.status).to eq("enqueued")
      expect(paused.reload.status).to eq("paused")
    end
  end

  describe "#record_user!" do
    after { MaintenanceOnSteroids.current_user_resolver = nil }

    it "stores user info from configured resolver" do
      user = User.create!(email: "alice@example.com", password: "password", name: "Alice", role: "admin")
      MaintenanceOnSteroids.current_user_resolver = -> { user }

      run.record_user!
      expect(run.user_id).to eq(user.id.to_s)
      expect(run.user_type).to eq("User")
      expect(run.user_email).to eq("alice@example.com")
    end

    it "works when user does not respond to email" do
      user_obj = Struct.new(:id).new(7)
      MaintenanceOnSteroids.current_user_resolver = -> { user_obj }

      run.record_user!
      expect(run.user_id).to eq("7")
      expect(run.user_email).to be_nil
    end

    it "does nothing when no resolver is configured" do
      MaintenanceOnSteroids.current_user_resolver = nil
      run.record_user!
      expect(run.user_id).to be_nil
      expect(run.user_type).to be_nil
      expect(run.user_email).to be_nil
    end

    it "handles resolver errors gracefully" do
      MaintenanceOnSteroids.current_user_resolver = -> { raise "no user" }
      run.record_user!
      expect(run.user_id).to be_nil
    end
  end

  describe "#user_display" do
    after do
      MaintenanceOnSteroids.user_display_formatter = nil
    end

    it "returns nil when no user recorded" do
      expect(run.user_display).to be_nil
    end

    it "shows email by default when present" do
      run.update!(user_id: "1", user_type: "User", user_email: "alice@example.com")
      expect(run.user_display).to eq("alice@example.com")
    end

    it "falls back to Type#ID when no email" do
      run.update!(user_id: "1", user_type: "User")
      expect(run.user_display).to eq("User#1")
    end

    it "uses custom formatter when configured" do
      run.update!(user_id: "1", user_type: "User", user_email: "alice@example.com")
      MaintenanceOnSteroids.user_display_formatter = ->(r) { "Custom: #{r.user_email} (#{r.user_id})" }
      expect(run.user_display).to eq("Custom: alice@example.com (1)")
    end

    it "falls back on formatter error" do
      run.update!(user_id: "1", user_type: "User")
      MaintenanceOnSteroids.user_display_formatter = ->(_r) { raise "boom" }
      expect(run.user_display).to eq("User#1")
    end
  end

  describe "associations" do
    it "has many artifacts" do
      run.artifacts.create!(
        name: "test",
        kind: "output",
        artifact_type: "jsonb",
        data_jsonb: { foo: "bar" }
      )
      expect(run.artifacts.count).to eq(1)
    end

    it "destroys artifacts on destroy" do
      run.artifacts.create!(name: "test", kind: "output", artifact_type: "jsonb")
      expect { run.destroy }.to change(MaintenanceOnSteroids::Artifact, :count).by(-1)
    end
  end
end
