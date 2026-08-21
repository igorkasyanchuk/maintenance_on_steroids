require "rails_helper"

RSpec.describe MaintenanceOnSteroids::Artifact, "previews" do
  let(:run) { MaintenanceOnSteroids::Run.create!(task_class: "CsvExportTask", status: "completed") }
  let(:cap) { described_class::PREVIEW_BYTES }

  def build(type, **attrs)
    run.artifacts.new(name: "a", kind: "output", artifact_type: type, **attrs).tap(&:refresh_metadata!)
  end

  it "parses a small CSV in full" do
    artifact = build("csv", data_blob: "id,name\n1,Igor\n2,Ada\n")
    expect(artifact.csv_rows).to eq([%w[id name], %w[1 Igor], %w[2 Ada]])
    expect(artifact.preview_truncated?).to be(false)
  end

  it "caps a large CSV at PREVIEW_BYTES and reports truncation" do
    row = "#{'x' * 40},#{'y' * 40}\n"
    artifact = build("csv", data_blob: row * ((cap / row.bytesize) + 500))

    rows = artifact.csv_rows

    expect(artifact.preview_truncated?).to be(true)
    expect(rows.sum { |r| r.join(",").bytesize + 1 }).to be <= cap
    # Cut back to a line boundary, so every parsed row is complete.
    expect(rows.map(&:size).uniq).to eq([2])
  end

  it "caps a large text artifact" do
    artifact = build("text", data_text: "line\n" * (cap / 5 + 1000))

    expect(artifact.preview_text.bytesize).to be <= cap
    expect(artifact.preview_truncated?).to be(true)
    expect(artifact.preview_text).to end_with("\n")
  end

  it "returns nil preview_text for a blob artifact" do
    expect(build("blob", data_blob: "\x00\x01").preview_text).to be_nil
  end

  it "trims an oversized jsonb document instead of generating all of it" do
    big = (1..5_000).to_h { |i| ["key_#{i}", "v" * 100] }
    artifact = build("jsonb", data_jsonb: big)

    expect(artifact.preview_truncated?).to be(true)

    parsed = JSON.parse(artifact.preview_text)
    expect(parsed.size).to eq(described_class::PREVIEW_ENTRIES)
    expect(parsed.keys.first).to eq("key_1")
    expect(artifact.preview_text.bytesize).to be <= cap
  end

  it "leaves a scalar jsonb payload alone" do
    artifact = build("jsonb", data_jsonb: "just a string")
    expect(artifact.preview_text).to eq(JSON.pretty_generate("just a string"))
  end

  it "returns the whole payload when under the cap" do
    artifact = build("jsonb", data_jsonb: { "a" => 1 })
    expect(artifact.preview_text).to eq(JSON.pretty_generate("a" => 1))
    expect(artifact.preview_truncated?).to be(false)
  end
end
