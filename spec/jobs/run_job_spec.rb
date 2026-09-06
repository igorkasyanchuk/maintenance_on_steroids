require "rails_helper"

RSpec.describe MaintenanceOnSteroids::RunJob, type: :job do
  include ActiveJob::TestHelper
  def create_users(count, name: "Alice")
    count.times do |i|
      User.create!(
        name: name,
        email: "runjob-user-#{i}-#{SecureRandom.hex(4)}@test.com",
        password: "password",
        active: true,
        age: 1
      )
    end
  end

  def create_run(task_class: "UpdateUsersTask", status: "enqueued", params: { "name" => "Alice", "age" => "42" })
    MaintenanceOnSteroids::Run.create!(task_class: task_class, status: status, params: params)
  end

  describe "collection tasks" do
    it "processes the whole collection and completes the run" do
      create_users(3)
      run = create_run

      described_class.perform_now(run.id)

      run.reload
      expect(run.status).to eq("completed")
      expect(run.progress_current).to eq(3)
      expect(run.progress_total).to eq(3)
      expect(run.completed_at).to be_present
      expect(run.started_at).to be_present
      expect(User.where(name: "Alice").pluck(:age)).to all(eq(42))
    end

    it "fires after_complete callbacks (persisting the result artifact)" do
      create_users(2)
      run = create_run

      described_class.perform_now(run.id)

      artifact = run.artifacts.find_by(name: "result", kind: "output")
      expect(artifact).to be_present
      expect(artifact.data_jsonb.size).to eq(2)
    end
  end

  describe "callable tasks" do
    it "runs call and completes" do
      run = create_run(task_class: "SimpleCallableTask", params: {})

      described_class.perform_now(run.id)

      run.reload
      expect(run.status).to eq("completed")
      expect(run.completed_at).to be_present
    end
  end

  describe "artifact auto-flush" do
    # Task that writes an artifact during process but never calls save!
    # or uses after_complete -- relies entirely on RunJob auto-flush.
    def define_autoflush_task!
      klass = Class.new(MaintenanceOnSteroids::Task) do
        about { title "Auto Flush" }
        artifact :seen, type: :jsonb, default: {}

        def collection = User.all
        def process(user) = artifacts[:seen][user.id.to_s] = user.name
      end
      stub_const("AutoFlushTask", klass)
      MaintenanceOnSteroids::JobRegistry.register(klass)
    end

    it "persists artifacts written during process without an explicit save" do
      create_users(3)
      define_autoflush_task!
      run = create_run(task_class: "AutoFlushTask", params: {})

      described_class.perform_now(run.id)

      artifact = run.artifacts.find_by(name: "seen", kind: "output")
      expect(artifact).to be_present
      expect(artifact.data_jsonb.size).to eq(3)
    end

    it "persists in-progress artifacts when the run is cancelled mid-flight" do
      create_users(5)
      define_autoflush_task!
      run = create_run(task_class: "AutoFlushTask", params: {})

      # Flip to cancelling after the first record is processed.
      allow_any_instance_of(AutoFlushTask).to receive(:process).and_wrap_original do |orig, user|
        orig.call(user)
        run.update!(status: "cancelling") if run.reload.running?
      end

      described_class.perform_now(run.id)

      run.reload
      expect(run.status).to eq("cancelled")
      artifact = run.artifacts.find_by(name: "seen", kind: "output")
      expect(artifact).to be_present
      expect(artifact.data_jsonb.size).to be >= 1
    end
  end

  describe "execution guards" do
    it "does nothing for a cancelled run" do
      create_users(1)
      run = create_run(status: "cancelled")

      described_class.perform_now(run.id)

      expect(run.reload.status).to eq("cancelled")
      expect(User.where(name: "Alice").pluck(:age)).to all(eq(1))
    end

    it "does nothing for a completed run" do
      create_users(1)
      run = create_run(status: "completed")

      described_class.perform_now(run.id)

      expect(run.reload.status).to eq("completed")
      expect(User.where(name: "Alice").pluck(:age)).to all(eq(1))
    end

    it "does not re-execute an errored run delivered again by a retry" do
      create_users(1)
      run = create_run(status: "errored")

      described_class.perform_now(run.id)

      expect(run.reload.status).to eq("errored")
      expect(User.where(name: "Alice").pluck(:age)).to all(eq(1))
    end
  end

  describe "pause/cancel requested while the job was queued" do
    it "honors a cancel issued before the job started" do
      create_users(2)
      run = create_run(status: "cancelling")

      described_class.perform_now(run.id)

      run.reload
      expect(run.status).to eq("cancelled")
      expect(run.completed_at).to be_present
      expect(User.where(name: "Alice").pluck(:age)).to all(eq(1))
    end

    it "honors a pause issued before the job started" do
      create_users(2)
      run = create_run(status: "pausing")

      described_class.perform_now(run.id)

      expect(run.reload.status).to eq("paused")
      expect(User.where(name: "Alice").pluck(:age)).to all(eq(1))
    end
  end

  describe "error handling" do
    let(:failing_task_class) do
      Class.new(MaintenanceOnSteroids::Task) do
        @error_callback_fired = false

        class << self
          attr_accessor :error_callback_fired
        end

        after_error -> { self.class.error_callback_fired = true }

        def collection
          User.where(active: true)
        end

        def process(_user)
          raise "boom on purpose"
        end
      end
    end

    before do
      stub_const("FailingTask", failing_task_class)
      MaintenanceOnSteroids::JobRegistry.register(FailingTask)
    end

    it "marks the run errored, records the message and re-raises" do
      create_users(1)
      run = create_run(task_class: "FailingTask", params: {})

      expect { described_class.perform_now(run.id) }.to raise_error(/boom on purpose/)

      run.reload
      expect(run.status).to eq("errored")
      expect(run.error_message).to include("boom on purpose")
      expect(run.error_backtrace).to be_present
      expect(run.completed_at).to be_present
      expect(FailingTask.error_callback_fired).to be true
    end
  end

  describe "after_start callbacks" do
    let(:start_counting_task_class) do
      Class.new(MaintenanceOnSteroids::Task) do
        @start_count = 0

        class << self
          attr_accessor :start_count
        end

        after_start -> { self.class.start_count += 1 }

        def call
          true
        end
      end
    end

    before do
      stub_const("StartCountingTask", start_counting_task_class)
      MaintenanceOnSteroids::JobRegistry.register(StartCountingTask)
    end

    it "fires on the first start only, not on resumptions" do
      run = create_run(task_class: "StartCountingTask", params: {})

      described_class.perform_now(run.id)
      expect(StartCountingTask.start_count).to eq(1)

      # Simulate a resumption: run already has started_at, goes back to enqueued
      run.reload.update!(status: "paused")
      run.resume!
      perform_enqueued_jobs

      expect(StartCountingTask.start_count).to eq(1)
      expect(run.reload.status).to eq("completed")
    end
  end

  describe "completion compare-and-set" do
    let(:last_moment_cancel_task_class) do
      Class.new(MaintenanceOnSteroids::Task) do
        def collection
          User.where(active: true)
        end

        def process(user)
          user.update!(age: 42)
          # Simulate an operator cancelling right after the final per-record
          # status check, before the job writes "completed".
          MaintenanceOnSteroids::Run.where(id: run.id).update_all(status: "cancelling")
        end
      end
    end

    before do
      stub_const("LastMomentCancelTask", last_moment_cancel_task_class)
      MaintenanceOnSteroids::JobRegistry.register(LastMomentCancelTask)
    end

    it "does not overwrite a last-moment cancel with completed" do
      create_users(1)
      run = create_run(task_class: "LastMomentCancelTask", params: {})

      described_class.perform_now(run.id)

      run.reload
      expect(run.status).to eq("cancelled")
      expect(run.completed_at).to be_present
    end
  end

  describe "mid-run pause and resume" do
    let(:processed_ids) { [] }

    let(:pausing_task_class) do
      ids = processed_ids
      Class.new(MaintenanceOnSteroids::Task) do
        @_processed_ids = ids

        def collection
          User.where(active: true)
        end

        def process(user)
          self.class.instance_variable_get(:@_processed_ids) << user.id
          # Request a pause after the first record.
          if self.class.instance_variable_get(:@_processed_ids).size == 1
            MaintenanceOnSteroids::Run.where(id: run.id).update_all(status: "pausing")
          end
        end
      end
    end

    before do
      stub_const("PausingTask", pausing_task_class)
      MaintenanceOnSteroids::JobRegistry.register(PausingTask)
    end

    it "pauses mid-run, then resumes from the cursor without reprocessing" do
      create_users(3)
      all_ids = User.where(active: true).order(:id).pluck(:id)
      run = create_run(task_class: "PausingTask", params: {})

      described_class.perform_now(run.id)

      run.reload
      expect(run.status).to eq("paused")
      expect(run.progress_current).to eq(1)
      expect(run.cursor).to eq(all_ids.first.to_s)
      expect(processed_ids).to eq([all_ids.first])

      # Resume: process the remaining records exactly once.
      run.resume!
      perform_enqueued_jobs

      run.reload
      expect(run.status).to eq("completed")
      expect(run.progress_current).to eq(3)
      expect(processed_ids).to eq(all_ids)
    end
  end
end
