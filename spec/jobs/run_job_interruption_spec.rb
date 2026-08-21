require "rails_helper"
require "active_job/continuation/test_helper"

# Regression coverage for the interruption path: ActiveJob::Continuation::Interrupt
# subclasses Exception, so it is invisible to `rescue => e` in RunJob#perform.
RSpec.describe "RunJob interruption", type: :job do
  include ActiveJob::Continuation::TestHelper

  before { ActiveJob::Base.queue_adapter = :test }

  let!(:task_class) do
    klass = Class.new(MaintenanceOnSteroids::Task) do
      about { title "Interruptible Task" }
      artifact :report, type: :csv, headers: %w[id name]

      def collection
        User.where(active: true)
      end

      def process(user)
        artifacts.report << [user.id, user.name]
      end
    end
    stub_const("InterruptibleTask", klass)
    MaintenanceOnSteroids::JobRegistry.register(klass)
    klass
  end

  def create_users(count)
    count.times do |i|
      User.create!(name: "U#{i}", email: "interrupt-#{i}@test.com", password: "password", active: true)
    end
  end

  def run_for(task = "InterruptibleTask")
    MaintenanceOnSteroids::Run.create!(task_class: task, status: "enqueued", params: {})
  end

  def interrupt_after_third_record(run)
    third_id = User.where(active: true).order(:id).pluck(:id)[2]
    MaintenanceOnSteroids::RunJob.perform_later(run.id)
    interrupt_job_during_step(MaintenanceOnSteroids::RunJob, :process_collection, cursor: third_id) do
      perform_enqueued_jobs
    end
  end

  it "persists buffered artifact rows written before the interruption" do
    create_users(5)
    run = run_for

    interrupt_after_third_record(run)

    rows = run.artifacts.find_by(name: "report", kind: "output")&.data_blob.to_s
    expect(rows.lines.size).to eq(4) # header + 3 processed records
  end

  it "does not lose rows in the final artifact once the run resumes" do
    create_users(5)
    run = run_for
    all_names = User.where(active: true).order(:id).pluck(:name)

    interrupt_after_third_record(run)
    perform_enqueued_jobs

    run.reload
    expect(run.status).to eq("completed")
    expect(run.progress_current).to eq(5)

    csv = CSV.parse(run.artifacts.find_by(name: "report", kind: "output").data_blob)
    expect(csv.first).to eq(%w[id name])
    expect(csv.drop(1).map(&:last)).to eq(all_names)
  end

  it "marks the run enqueued while it waits to be resumed, so the reaper spares it" do
    create_users(5)
    run = run_for

    interrupt_after_third_record(run)

    expect(run.reload.status).to eq("enqueued")

    # Untouched for longer than the threshold, but it is queued, not dead.
    run.update_columns(updated_at: 2.hours.ago)
    expect { MaintenanceOnSteroids::Run.reap_stale!(threshold: 30.minutes) }
      .not_to change { run.reload.status }
  end

  it "leaves a pause requested before the interruption intact" do
    create_users(5)
    run = run_for
    MaintenanceOnSteroids::RunJob.perform_later(run.id)

    third_id = User.where(active: true).order(:id).pluck(:id)[2]
    interrupt_job_during_step(MaintenanceOnSteroids::RunJob, :process_collection, cursor: third_id) do
      MaintenanceOnSteroids::Run.where(id: run.id).update_all(status: "pausing")
      perform_enqueued_jobs
    end

    # The interrupt handler compare-and-sets on "running" only, so it must not
    # overwrite an operator's pause request.
    expect(run.reload.status).not_to eq("enqueued")
  end
end
