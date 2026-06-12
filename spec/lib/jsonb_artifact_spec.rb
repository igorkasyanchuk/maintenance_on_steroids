require "rails_helper"

RSpec.describe MaintenanceOnSteroids::JsonbArtifact do
  let(:run) do
    MaintenanceOnSteroids::Run.create!(
      task_class: "UpdateUsersTask",
      status: "running"
    )
  end

  let(:artifact_record) do
    run.artifacts.create!(
      name: "result",
      kind: "output",
      artifact_type: "jsonb",
      data_jsonb: { "existing_key" => "existing_value" }
    )
  end

  subject { described_class.new(artifact_record) }

  it "behaves like a hash" do
    expect(subject["existing_key"]).to eq("existing_value")
  end

  it "supports indifferent access" do
    expect(subject[:existing_key]).to eq("existing_value")
  end

  it "allows modification" do
    subject["new_key"] = "new_value"
    expect(subject["new_key"]).to eq("new_value")
  end

  it "persists on save!" do
    subject["added"] = { "nested" => true }
    subject.save!

    reloaded = run.artifacts.find_by(name: "result")
    expect(reloaded.data_jsonb["added"]).to eq({ "nested" => true })
  end

  it "exposes the underlying record" do
    expect(subject.record).to eq(artifact_record)
  end
end
