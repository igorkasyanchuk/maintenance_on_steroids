require "rails_helper"

RSpec.describe MaintenanceOnSteroids::Artifact, "size limit" do
  let(:run) { MaintenanceOnSteroids::Run.create!(task_class: "CsvExportTask", status: "running") }

  around do |example|
    original = MaintenanceOnSteroids.max_artifact_size
    MaintenanceOnSteroids.max_artifact_size = 1024
    example.run
    MaintenanceOnSteroids.max_artifact_size = original
  end

  def build(type, **attrs)
    run.artifacts.new(name: "a", kind: "output", artifact_type: type, **attrs)
  end

  it "accepts a payload inside the limit" do
    expect(build("text", data_text: "x" * 1000)).to be_valid
  end

  it "rejects an oversized text artifact with an actionable message" do
    artifact = build("text", data_text: "x" * 2000)

    expect(artifact).not_to be_valid
    expect(artifact.errors.full_messages.join).to match(/over the .* limit/)
    expect(artifact.errors.full_messages.join).to include("max_artifact_size")
  end

  it "rejects oversized blob, csv and jsonb payloads too" do
    expect(build("csv", data_blob: "x" * 2000)).not_to be_valid
    expect(build("blob", data_blob: "x" * 2000)).not_to be_valid
    expect(build("jsonb", data_jsonb: { "k" => "x" * 2000 })).not_to be_valid
  end

  it "fails the save rather than writing a truncated row" do
    expect { build("text", data_text: "x" * 2000).save! }
      .to raise_error(ActiveRecord::RecordInvalid, /over the/)
    expect(run.artifacts.count).to eq(0)
  end

  it "imposes no limit when the setting is nil" do
    MaintenanceOnSteroids.max_artifact_size = nil

    expect(build("text", data_text: "x" * 100_000)).to be_valid
  end
end
