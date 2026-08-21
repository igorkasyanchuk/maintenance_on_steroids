require "rails_helper"

# A callable task is one Continuable step, so without checkpoint! a long call
# ignores Pause until it returns.
RSpec.describe "Task#checkpoint!", type: :job do
  let!(:task_class) do
    klass = Class.new(MaintenanceOnSteroids::Task) do
      about { title "Checkpointing Task" }
      cattr_accessor :units_done, default: 0
      cattr_accessor :pause_after, default: nil
      artifact :log, type: :text

      def call
        5.times do |i|
          checkpoint!
          self.class.units_done += 1
          artifacts.log.puts("unit #{i}")
          if self.class.pause_after && self.class.units_done == self.class.pause_after
            MaintenanceOnSteroids::Run.where(id: run.id).update_all(status: "pausing")
          end
        end
      end
    end
    stub_const("CheckpointingTask", klass)
    MaintenanceOnSteroids::JobRegistry.register(klass)
    klass
  end

  before do
    CheckpointingTask.units_done = 0
    CheckpointingTask.pause_after = nil
  end

  def run_record
    MaintenanceOnSteroids::Run.create!(task_class: "CheckpointingTask", status: "enqueued", params: {})
  end

  it "runs straight through when nothing is pending" do
    run = run_record

    MaintenanceOnSteroids::RunJob.perform_now(run.id)

    expect(run.reload.status).to eq("completed")
    expect(CheckpointingTask.units_done).to eq(5)
  end

  it "stops mid-call when a pause is requested" do
    CheckpointingTask.pause_after = 2
    run = run_record

    MaintenanceOnSteroids::RunJob.perform_now(run.id)

    expect(run.reload.status).to eq("paused")
    # The third checkpoint honoured the pause instead of finishing all five.
    expect(CheckpointingTask.units_done).to eq(2)
  end

  it "flushes what the task produced before stopping" do
    CheckpointingTask.pause_after = 2
    run = run_record

    MaintenanceOnSteroids::RunJob.perform_now(run.id)

    expect(run.artifacts.find_by(name: "log")&.data_text).to eq("unit 0\nunit 1\n")
  end

  it "cancels mid-call too" do
    klass = CheckpointingTask
    run = run_record
    allow(klass).to receive(:units_done).and_call_original
    klass.pause_after = nil

    # Request cancellation after the first unit.
    original = klass.instance_method(:call)
    klass.define_method(:call) do
      checkpoint!
      MaintenanceOnSteroids::Run.where(id: run.id).update_all(status: "cancelling")
      checkpoint!
      raise "should not reach here"
    end

    MaintenanceOnSteroids::RunJob.perform_now(run.id)

    expect(run.reload.status).to eq("cancelled")
  ensure
    klass.define_method(:call, original) if original
  end

  it "is a harmless no-op outside a job" do
    expect { CheckpointingTask.new(nil).checkpoint! }.not_to raise_error
  end
end
