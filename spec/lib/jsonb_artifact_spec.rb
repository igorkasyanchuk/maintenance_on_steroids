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

  describe "hash-copy operations (detached copies)" do
    it "supports merge" do
      merged = subject.merge("other" => 1)
      expect(merged["existing_key"]).to eq("existing_value")
      expect(merged["other"]).to eq(1)
    end

    it "supports dup" do
      copy = subject.dup
      copy["only_in_copy"] = true
      expect(copy["only_in_copy"]).to be true
      expect(subject.key?("only_in_copy")).to be false
    end

    it "supports except" do
      remaining = subject.except("existing_key")
      expect(remaining.key?("existing_key")).to be false
    end

    it "can be constructed from a plain hash" do
      detached = described_class.new("a" => 1)
      expect(detached[:a]).to eq(1)
      expect(detached.record).to be_nil
    end

    it "raises a clear error when save! is called on a detached copy" do
      expect { subject.dup.save! }.to raise_error(/detached JsonbArtifact/)
    end

    it "still saves the original after copies were made" do
      subject.merge("x" => 1)
      subject["persisted"] = true
      subject.save!
      expect(artifact_record.reload.data_jsonb["persisted"]).to be true
    end
  end
end
