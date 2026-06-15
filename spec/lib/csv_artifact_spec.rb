require "rails_helper"

RSpec.describe MaintenanceOnSteroids::CsvArtifact do
  let(:run) { MaintenanceOnSteroids::Run.create!(task_class: "ExportProductsTask", status: "running") }

  def new_record(blob: nil)
    run.artifacts.new(name: "export", kind: "output", artifact_type: "csv", data_blob: blob, file_name: "export.csv")
  end

  it "appends rows and renders CSV with headers on save" do
    artifact = described_class.new(new_record, headers: %w[id name])
    artifact << [1, "Alice"]
    artifact << [2, "Bob"]
    artifact.save!

    record = run.artifacts.find_by(name: "export")
    expect(record.data_blob).to eq("id,name\n1,Alice\n2,Bob\n")
    expect(record.content_type).to eq("text/csv")
  end

  it "is dirty only after appending" do
    artifact = described_class.new(new_record, headers: %w[id name])
    expect(artifact).not_to be_dirty
    artifact << [1, "Alice"]
    expect(artifact).to be_dirty
    artifact.save!
    expect(artifact).not_to be_dirty
  end

  it "reloads existing rows and skips the header on re-open (resume-safe)" do
    artifact = described_class.new(new_record(blob: "id,name\n1,Alice\n"), headers: %w[id name])
    expect(artifact.size).to eq(1)
    artifact << [2, "Bob"]
    artifact.save!

    expect(run.artifacts.find_by(name: "export").data_blob).to eq("id,name\n1,Alice\n2,Bob\n")
  end

  it "records row count and byte size in metadata" do
    artifact = described_class.new(new_record, headers: %w[id name])
    artifact << [1, "Alice"]
    artifact << [2, "Bob"]
    artifact.save!

    record = run.artifacts.find_by(name: "export")
    expect(record.metadata["rows"]).to eq(3) # header + 2 data rows
    expect(record.metadata["bytes"]).to be > 0
    expect(record.summary).to match(/3 rows/)
  end

  it "is downloadable" do
    artifact = described_class.new(new_record, headers: %w[id name])
    artifact << [1, "Alice"]
    artifact.save!
    expect(run.artifacts.find_by(name: "export")).to be_downloadable
  end
end
