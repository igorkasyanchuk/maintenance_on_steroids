require "rails_helper"

RSpec.describe "RunJob error recovery", type: :job do
  include ActiveJob::TestHelper

  before { ActiveJob::Base.queue_adapter = :test }

  let!(:task_class) do
    klass = Class.new(MaintenanceOnSteroids::Task) do
      about { title "Flaky Task" }
      cattr_accessor :processed, default: []
      cattr_accessor :raise_on, default: 3

      def collection
        User.where(active: true)
      end

      def process(user)
        self.class.processed << user.id
        raise "transient failure" if self.class.processed.size == self.class.raise_on
      end
    end
    stub_const("FlakyTask", klass)
    MaintenanceOnSteroids::JobRegistry.register(klass)
    klass
  end

  before do
    FlakyTask.processed = []
    FlakyTask.raise_on = 3
    5.times { |i| User.create!(name: "F#{i}", email: "flaky-#{i}@test.com", password: "password", active: true) }
  end

  def run_flaky
    MaintenanceOnSteroids::Run.create!(task_class: "FlakyTask", status: "enqueued", params: {})
  end

  it "errors the run and does not leave a phantom retry queued behind it" do
    run = run_flaky
    MaintenanceOnSteroids::RunJob.perform_later(run.id)

    perform_enqueued_jobs rescue nil

    expect(run.reload.status).to eq("errored")
    expect(run.progress_current).to eq(2)
    # resume_errors_after_advancing is off: Continuable must not silently
    # re-enqueue a job that would no-op against the now-terminal run.
    expect(enqueued_jobs).to be_empty
  end

  it "lets an operator resume an errored run from where it stopped" do
    run = run_flaky
    MaintenanceOnSteroids::RunJob.perform_later(run.id)
    perform_enqueued_jobs rescue nil
    expect(run.reload.status).to eq("errored")

    FlakyTask.raise_on = nil # the transient cause is gone
    expect(run.resumable?).to be(true)
    expect(run.resume!).to be(true)
    expect(run.reload.error_message).to be_nil
    expect(run.completed_at).to be_nil

    perform_enqueued_jobs

    run.reload
    expect(run.status).to eq("completed")
    expect(run.progress_current).to eq(5)

    all_ids = User.where(active: true).order(:id).pluck(:id)
    expect(FlakyTask.processed.uniq).to eq(all_ids)

    # The record that raised never advanced the cursor, so it is retried once
    # on resume -- at-least-once for the failing record. Every other record is
    # processed exactly once; none are skipped.
    retried = all_ids[2]
    expect(FlakyTask.processed.tally).to eq(all_ids.index_with { |id| id == retried ? 2 : 1 })
  end
end
