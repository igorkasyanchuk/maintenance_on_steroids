require "rails_helper"

RSpec.describe MaintenanceOnSteroids::Artifact, type: :model do
  let(:run) do
    MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "enqueued")
  end

  describe "validations" do
    it "requires name" do
      a = run.artifacts.build(kind: "output", artifact_type: "jsonb")
      expect(a).not_to be_valid
    end

    it "validates kind" do
      a = run.artifacts.build(name: "test", kind: "invalid", artifact_type: "jsonb")
      expect(a).not_to be_valid
    end

    it "validates artifact_type" do
      a = run.artifacts.build(name: "test", kind: "output", artifact_type: "invalid")
      expect(a).not_to be_valid
    end
  end

  # ArtifactsProxy#write_and_persist rescues ActiveRecord::RecordNotUnique to
  # handle concurrent writers, which only works if the index the install
  # migration adds actually exists. Guards schema drift in the dummy app.
  describe "unique (run_id, name, kind) index" do
    it "rejects a duplicate name+kind for the same run" do
      run.artifacts.create!(name: "dup", kind: "output", artifact_type: "jsonb")

      expect {
        run.artifacts.create!(name: "dup", kind: "output", artifact_type: "jsonb")
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows the same name for a different kind" do
      run.artifacts.create!(name: "same", kind: "output", artifact_type: "jsonb")

      expect {
        run.artifacts.create!(name: "same", kind: "input", artifact_type: "blob")
      }.not_to raise_error
    end
  end

  describe "#data" do
    it "returns jsonb data" do
      a = run.artifacts.create!(name: "test", kind: "output", artifact_type: "jsonb", data_jsonb: { "foo" => "bar" })
      expect(a.data).to eq({ "foo" => "bar" })
    end

    it "returns blob data" do
      a = run.artifacts.create!(name: "test", kind: "output", artifact_type: "blob", data_blob: "binary content")
      expect(a.data).to eq("binary content")
    end

    it "returns text data" do
      a = run.artifacts.create!(name: "test", kind: "output", artifact_type: "text", data_text: "hello")
      expect(a.data).to eq("hello")
    end
  end

  describe "#downloadable?" do
    it "is downloadable for blob with data" do
      a = run.artifacts.create!(name: "test", kind: "output", artifact_type: "blob", data_blob: "data")
      expect(a).to be_downloadable
    end

    it "is not downloadable for jsonb" do
      a = run.artifacts.create!(name: "test", kind: "output", artifact_type: "jsonb")
      expect(a).not_to be_downloadable
    end
  end

  describe "#human_size" do
    it "returns size in bytes" do
      a = run.artifacts.create!(name: "test", kind: "output", artifact_type: "blob", data_blob: "x" * 500)
      expect(a.human_size).to eq("500 B")
    end

    it "returns size in KB" do
      a = run.artifacts.create!(name: "test", kind: "output", artifact_type: "blob", data_blob: "x" * 2048)
      expect(a.human_size).to eq("2.0 KB")
    end
  end

  describe "#display_value" do
    it "pretty-prints JSON" do
      a = run.artifacts.create!(name: "test", kind: "output", artifact_type: "jsonb", data_jsonb: { "a" => 1 })
      expect(a.display_value).to include('"a": 1')
    end

    it "returns text for text artifacts" do
      a = run.artifacts.create!(name: "test", kind: "output", artifact_type: "text", data_text: "hello")
      expect(a.display_value).to eq("hello")
    end

    it "returns file info for blob artifacts" do
      a = run.artifacts.create!(name: "test", kind: "output", artifact_type: "blob", data_blob: "data", file_name: "report.csv")
      expect(a.display_value).to include("report.csv")
    end
  end
end
