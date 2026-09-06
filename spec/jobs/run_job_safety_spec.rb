require "rails_helper"

RSpec.describe "RunJob production safety", type: :job do
  include ActiveJob::TestHelper
  def define_task(name, &body)
    stub_const(name, Class.new(MaintenanceOnSteroids::Task, &body))
  end

  def run_for(name, **attributes)
    MaintenanceOnSteroids::Run.create!(task_class: name, **attributes)
  end

  it "ignores an interleaved duplicate delivery of the same job" do
    define_task("DuplicateDeliveryTask") do
      class_attribute :calls, default: 0
      def call
        self.class.calls += 1
        if self.class.calls == 1
          duplicate = MaintenanceOnSteroids::RunJob.new(run.id)
          duplicate.job_id = run.active_job_id
          duplicate.perform_now
        end
      end
    end
    run = run_for("DuplicateDeliveryTask")
    MaintenanceOnSteroids::RunJob.perform_now(run.id)
    expect(DuplicateDeliveryTask.calls).to eq(1)
    expect(run.reload.status).to eq("completed")
    expect(run.execution_token).to be_nil
  end

  it "does not restart a paused run or instantiate a deleted terminal task" do
    %w[paused completed cancelled errored].each do |status|
      run = run_for("DeletedTask", status: status)
      expect { MaintenanceOnSteroids::RunJob.perform_now(run.id) }.not_to raise_error
      expect(run.reload.status).to eq(status)
    end
  end

  it "rejects an obsolete job after resume and allows the new attempt" do
    run = run_for("SimpleCallableTask", status: "paused", active_job_id: "old-job")
    run.resume!
    stale_job = MaintenanceOnSteroids::RunJob.new(run.id)
    stale_job.job_id = "old-job"
    stale_job.perform_now
    expect(run.reload.status).to eq("enqueued")
    perform_enqueued_jobs
    expect(run.reload.status).to eq("completed")
  end

  it "stops a reaped worker without overwriting the new attempt or its artifacts" do
    define_task("ReapedWorkerTask") do
      artifact :report, type: :text
      def call
        artifacts.report << "old worker"
        run.update_columns(updated_at: 2.hours.ago)
        MaintenanceOnSteroids::Run.reap_stale!
        MaintenanceOnSteroids::Run.find(run.id).resume!
        artifacts.report.save! # The old wrapper must be fenced too.
        raise "old worker continued"
      end
    end
    run = run_for("ReapedWorkerTask")
    MaintenanceOnSteroids::RunJob.perform_now(run.id)
    expect(run.reload.status).to eq("enqueued")
    expect(run.execution_token).to be_nil
    expect(run.artifacts.count).to eq(0)
  end

  it "reports an artifact flush failure and never emits success" do
    define_task("FailedOutputTask") do
      artifact :report, type: :jsonb
      def call
        artifacts.report["payload"] = "x" * 100
      end
    end
    original_limit = MaintenanceOnSteroids.max_artifact_size
    MaintenanceOnSteroids.max_artifact_size = 20
    run = run_for("FailedOutputTask")
    successes = []
    subscriber = ActiveSupport::Notifications.subscribe("succeeded.maintenance_on_steroids") { successes << true }
    expect { MaintenanceOnSteroids::RunJob.perform_now(run.id) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(run.reload.status).to eq("errored")
    expect(run.error_message).to include("over the")
    expect(run.artifacts.count).to eq(0)
    expect(successes).to be_empty
  ensure
    MaintenanceOnSteroids.max_artifact_size = original_limit
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "errors rather than advertising a pause when its output cannot be saved" do
    define_task("FailedPauseOutputTask") do
      artifact :report, type: :text
      def call
        artifacts.report << "must persist"
        run.pause!
        checkpoint!
      end
    end
    allow_any_instance_of(MaintenanceOnSteroids::TextArtifact).to receive(:save!).and_raise("storage down")
    run = run_for("FailedPauseOutputTask")
    expect { MaintenanceOnSteroids::RunJob.perform_now(run.id) }.to raise_error("storage down")
    expect(run.reload.status).to eq("errored")
    expect(run.execution_token).to be_nil
    expect(run.error_message).to eq("storage down")
  end

  it "does not instantiate arbitrary classes from persisted task names" do
    run = run_for("Object")
    expect { MaintenanceOnSteroids::RunJob.perform_now(run.id) }
      .to raise_error(ArgumentError, "Unknown maintenance task: Object")
    expect(run.reload.status).to eq("errored")
  end

  it "makes callback output available before observers see success" do
    define_task("FinalOutputTask") do
      artifact :report, type: :text
      after_complete -> { artifacts.report << "ready" }
      def call; end
    end
    run = run_for("FinalOutputTask")
    observed = []
    subscriber = ActiveSupport::Notifications.subscribe("succeeded.maintenance_on_steroids") do
      observed << run.artifacts.find_by(name: "report")&.data_text
    end
    MaintenanceOnSteroids::RunJob.perform_now(run.id)
    expect(observed).to eq(["ready"])
    expect(run.reload.status).to eq("completed")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "preserves the task exception when cleanup also fails" do
    define_task("CleanupFailureTask") do
      artifact :report, type: :text
      def call
        artifacts.report << "output"
        raise "primary error"
      end
    end
    allow_any_instance_of(MaintenanceOnSteroids::TextArtifact).to receive(:save!).and_raise("storage down")
    run = run_for("CleanupFailureTask")
    expect { MaintenanceOnSteroids::RunJob.perform_now(run.id) }.to raise_error("primary error")
    expect(run.reload.error_message).to eq("primary error")
  end

  it "commits output and cursor together, discarding a failed record's buffer" do
    User.create!(email: "checkpoint@test.com", password: "password", name: "First")
    define_task("AtomicOutputTask") do
      artifact :report, type: :csv
      def collection; User.all; end
      def process(user); artifacts.report << [user.id]; end
    end
    run = run_for("AtomicOutputTask")
    allow_any_instance_of(MaintenanceOnSteroids::RunJob).to receive(:advance_progress!).and_raise("cursor write failed")
    expect { MaintenanceOnSteroids::RunJob.perform_now(run.id) }.to raise_error("cursor write failed")
    expect(run.reload.cursor).to be_nil
    expect(run.progress_current).to eq(0)
    expect(run.artifacts.count).to eq(0)
  end

  it "defers pause inside process until the entire record and its output are checkpointed" do
    user = User.create!(email: "record-pause@test.com", password: "password", name: "First")
    define_task("RecordCheckpointTask") do
      artifact :report, type: :csv
      def collection; User.all; end
      def process(user)
        artifacts.report << [user.id, "start"]
        run.pause!
        checkpoint!
        artifacts.report << [user.id, "end"]
      end
    end
    run = run_for("RecordCheckpointTask")
    MaintenanceOnSteroids::RunJob.perform_now(run.id)
    expect(run.reload.status).to eq("paused")
    expect(run.cursor).to eq(user.id.to_s)
    run.resume!
    perform_enqueued_jobs
    expect(run.reload.status).to eq("completed")
    expect(CSV.parse(run.artifacts.find_by!(name: "report").data_blob))
      .to eq([[user.id.to_s, "start"], [user.id.to_s, "end"]])
  end

  it "refreshes the callable heartbeat and stops after ownership is revoked" do
    define_task("HeartbeatTask") do
      def call
        run.update_columns(updated_at: 2.hours.ago)
        checkpoint!
        raise "heartbeat did not protect run" unless MaintenanceOnSteroids::Run.reap_stale! == 0
        run.update_columns(updated_at: 2.hours.ago)
        MaintenanceOnSteroids::Run.reap_stale!
        checkpoint!
        raise "continued after being reaped"
      end
    end
    run = run_for("HeartbeatTask")
    MaintenanceOnSteroids::RunJob.perform_now(run.id)
    expect(run.reload.status).to eq("errored")
    expect(run.error_message).to include("stale")
  end
end
