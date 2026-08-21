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

      expect { run.resume! }.to raise_error(NameError)

      run.reload
      expect(run.status).to eq("errored")
      expect(run.error_message).to match(/Failed to enqueue/)
      expect(run.active_job_id).to be_nil
    end
  end
end
