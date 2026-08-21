require "rails_helper"

RSpec.describe MaintenanceOnSteroids::Run, "#resume!" do
  def paused_run(task_class: "UpdateUsersTask")
    described_class.create!(task_class: task_class, status: "paused", params: {})
  end

  it "returns false for a status that cannot be resumed" do
    run = described_class.create!(task_class: "UpdateUsersTask", status: "running")
    expect(run.resume!).to be(false)
    expect(run.reload.status).to eq("running")
  end

  it "only lets one of two concurrent resumes win" do
    run = paused_run
    other = described_class.find(run.id)

    expect(run.resume!).to be(true)
    expect(other.resume!).to be(false)
  end

  context "when enqueuing fails" do
    it "does not strand the run in enqueued with no job behind it" do
      run = described_class.create!(task_class: "VanishedTask", status: "paused", params: {})

      expect { run.resume! }
        .to raise_error(MaintenanceOnSteroids::EnqueueFailed, /uninitialized constant VanishedTask/)

      run.reload
      expect(run.status).to eq("errored")
      expect(run.error_message).to match(/Failed to enqueue/)
      expect(run.active_job_id).to be_nil
    end

    it "keeps the original failure that errored the run" do
      run = described_class.create!(
        task_class: "VanishedTask",
        status: "errored",
        error_message: "NoMethodError: undefined method `frobnicate'",
        error_backtrace: "app/maintenance/vanished_task.rb:12:in `process'",
        params: {}
      )

      expect { run.resume! }.to raise_error(MaintenanceOnSteroids::EnqueueFailed)

      # The backtrace of the failure being investigated must survive a resume
      # attempt that itself fails -- it is the only record of why the run died.
      expect(run.reload.error_backtrace).to include("vanished_task.rb:12")
    end
  end

  it "clears the previous error only once the job is really queued" do
    run = described_class.create!(
      task_class: "UpdateUsersTask",
      status: "errored",
      error_message: "boom",
      error_backtrace: "somewhere.rb:1",
      completed_at: Time.current,
      params: {}
    )

    expect(run.resume!).to be(true)

    run.reload
    expect(run.status).to eq("enqueued")
    expect(run.error_message).to be_nil
    expect(run.error_backtrace).to be_nil
    expect(run.completed_at).to be_nil
  end
end
