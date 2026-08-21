require "rails_helper"

RSpec.describe MaintenanceOnSteroids::Run, ".prune!" do
  def run_aged(status, age)
    run = described_class.create!(task_class: "UpdateUsersTask", status: status, params: {})
    described_class.where(id: run.id).update_all(created_at: age.ago)
    run
  end

  it "deletes terminal runs older than the cutoff" do
    old = run_aged("completed", 100.days)

    expect { described_class.prune!(older_than: 90.days) }
      .to change { described_class.exists?(old.id) }.from(true).to(false)
  end

  it "keeps terminal runs inside the cutoff" do
    recent = run_aged("completed", 10.days)

    described_class.prune!(older_than: 90.days)

    expect(described_class.exists?(recent.id)).to be(true)
  end

  it "never prunes an active or paused run however old" do
    survivors = MaintenanceOnSteroids::Run::ACTIVE_STATUSES.map { |s| run_aged(s, 5.years) }

    described_class.prune!(older_than: 1.day)

    survivors.each { |r| expect(described_class.exists?(r.id)).to be(true) }
  end

  it "takes the artifacts with it" do
    old = run_aged("completed", 100.days)
    old.artifacts.create!(name: "r", kind: "output", artifact_type: "text", data_text: "x")

    expect { described_class.prune!(older_than: 90.days) }
      .to change { MaintenanceOnSteroids::Artifact.where(run_id: old.id).count }.from(1).to(0)
  end

  it "returns how many runs it deleted" do
    3.times { run_aged("errored", 100.days) }
    run_aged("completed", 1.day)

    expect(described_class.prune!(older_than: 90.days)).to eq(3)
  end

  it "can be narrowed to specific statuses" do
    completed = run_aged("completed", 100.days)
    errored   = run_aged("errored", 100.days)

    described_class.prune!(older_than: 90.days, statuses: %w[errored])

    expect(described_class.exists?(completed.id)).to be(true)
    expect(described_class.exists?(errored.id)).to be(false)
  end

  it "ignores a non-terminal status passed in explicitly" do
    running = run_aged("running", 100.days)

    described_class.prune!(older_than: 90.days, statuses: %w[running completed])

    expect(described_class.exists?(running.id)).to be(true)
  end
end
