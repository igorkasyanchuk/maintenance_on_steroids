require "rails_helper"

RSpec.describe MaintenanceOnSteroids::Run, "state transitions" do
  def run_with(status)
    described_class.create!(task_class: "UpdateUsersTask", status: status, params: {})
  end

  describe "#pause!" do
    it "moves a running run to pausing" do
      run = run_with("running")
      expect(run.pause!).to be(true)
      expect(run.reload.status).to eq("pausing")
    end

    it "does not overwrite a run that finished first" do
      run = run_with("running")
      # The worker completes between the operator's click and the write.
      described_class.where(id: run.id).update_all(status: "completed", completed_at: Time.current)

      expect(run.pause!).to be(false)
      expect(run.reload.status).to eq("completed")
    end

    it "refuses from a non-running status" do
      %w[enqueued paused cancelled completed errored].each do |status|
        expect(run_with(status).pause!).to be(false)
      end
    end
  end

  describe "#cancel!" do
    it "cancels an enqueued or paused run outright" do
      %w[enqueued paused].each do |status|
        run = run_with(status)
        expect(run.cancel!).to be(true)
        expect(run.reload.status).to eq("cancelled")
        expect(run.completed_at).to be_present
      end
    end

    it "requests cancellation from a running or pausing run" do
      %w[running pausing].each do |status|
        run = run_with(status)
        expect(run.cancel!).to be(true)
        expect(run.reload.status).to eq("cancelling")
      end
    end

    it "does not overwrite a run that finished first" do
      run = run_with("running")
      described_class.where(id: run.id).update_all(status: "completed", completed_at: Time.current)

      expect(run.cancel!).to be(false)
      expect(run.reload.status).to eq("completed")
    end

    it "refuses from a terminal status" do
      %w[cancelled completed errored].each do |status|
        expect(run_with(status).cancel!).to be(false)
      end
    end
  end
end
