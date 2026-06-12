require "rails_helper"

RSpec.describe MaintenanceOnSteroids::ArtifactsProxy do
  let(:run) do
    MaintenanceOnSteroids::Run.create!(
      task_class: "UpdateUsersTask",
      status: "running"
    )
  end

  let(:definitions) { UpdateUsersTask.artifact_definitions }
  subject { described_class.new(run, definitions) }

  describe "#[]" do
    it "does not persist an artifact record on read" do
      expect { subject[:result] }.not_to change(MaintenanceOnSteroids::Artifact, :count)
    end

    it "persists the lazily-built record on save!" do
      subject[:result]["foo"] = "bar"
      expect { subject.save!(:result) }.to change(MaintenanceOnSteroids::Artifact, :count).by(1)
      expect(run.artifacts.find_by(name: "result").data_jsonb["foo"]).to eq("bar")
    end

    it "reads back an already-persisted record" do
      run.artifacts.create!(name: "result", kind: "output", artifact_type: "jsonb", data_jsonb: { "x" => 1 })
      expect(subject[:result]["x"]).to eq(1)
    end

    it "returns a JsonbArtifact for jsonb type" do
      expect(subject[:result]).to be_a(MaintenanceOnSteroids::JsonbArtifact)
    end

    it "returns the same object on repeated access (cached)" do
      first = subject[:result]
      second = subject[:result]
      expect(first.object_id).to eq(second.object_id)
    end

    it "raises for unknown artifacts" do
      expect { subject[:nonexistent] = "foo" }.to raise_error(ArgumentError, /Unknown artifact/)
    end
  end

  describe "#[]=" do
    it "writes jsonb artifacts" do
      subject[:result] = { "key" => "value" }
      artifact = run.artifacts.find_by(name: "result")
      expect(artifact.data_jsonb).to eq({ "key" => "value" })
    end
  end

  describe "#save!" do
    it "saves a modified jsonb artifact" do
      subject[:result]["foo"] = "bar"
      subject.save!(:result)

      artifact = run.artifacts.find_by(name: "result")
      expect(artifact.data_jsonb["foo"]).to eq("bar")
    end
  end

  describe "#save_all!" do
    it "persists all modified cached artifacts" do
      jsonb_defn = MaintenanceOnSteroids::ArtifactDsl::ArtifactDefinition.new(:result, type: :jsonb, default: {})
      text_defn = MaintenanceOnSteroids::ArtifactDsl::ArtifactDefinition.new(:summary, type: :text)
      proxy = described_class.new(run, [jsonb_defn, text_defn])

      proxy[:result]["foo"] = "bar"
      proxy[:summary] << "hello"

      proxy.save_all!

      jsonb_artifact = run.artifacts.find_by(name: "result")
      text_artifact = run.artifacts.find_by(name: "summary")
      expect(jsonb_artifact.reload.data_jsonb["foo"]).to eq("bar")
      expect(text_artifact.reload.data_text).to eq("hello")
    end
  end

  describe "file type artifacts" do
    let(:file_run) do
      MaintenanceOnSteroids::Run.create!(
        task_class: "CsvExportTask",
        status: "running"
      )
    end

    let(:file_definitions) { CsvExportTask.artifact_definitions }
    let(:file_proxy) { described_class.new(file_run, file_definitions) }

    it "stores file artifacts as blob with explicit file_name" do
      file_proxy[:csv_file] = "id,name\n1,Alice"
      artifact = file_run.artifacts.find_by(name: "csv_file")
      expect(artifact.artifact_type).to eq("blob")
      expect(artifact.data_blob).to eq("id,name\n1,Alice")
      expect(artifact.file_name).to eq("users.csv")
    end

    it "auto-generates file_name when not specified in DSL" do
      defn = MaintenanceOnSteroids::ArtifactDsl::ArtifactDefinition.new(:export, type: :file)
      proxy = described_class.new(file_run, [defn])
      proxy[:export] = "data"
      artifact = file_run.artifacts.find_by(name: "export")
      expect(artifact.file_name).to match(/csv_export_task_\d{8}_\d{6}/)
    end

    it "is downloadable" do
      file_proxy[:csv_file] = "id,name\n1,Alice"
      artifact = file_run.artifacts.find_by(name: "csv_file")
      expect(artifact).to be_downloadable
    end
  end

  describe "text type artifacts" do
    let(:text_run) do
      MaintenanceOnSteroids::Run.create!(
        task_class: "SummarizeUsersTask",
        status: "running"
      )
    end

    let(:text_definitions) { SummarizeUsersTask.artifact_definitions }
    let(:text_proxy) { described_class.new(text_run, text_definitions) }

    it "returns a TextArtifact on read" do
      expect(text_proxy[:summary]).to be_a(MaintenanceOnSteroids::TextArtifact)
    end

    it "stores text via direct assignment" do
      text_proxy[:summary] = "Hello World"
      artifact = text_run.artifacts.find_by(name: "summary")
      expect(artifact.data_text).to eq("Hello World")
      expect(artifact.artifact_type).to eq("text")
    end

    it "supports incremental building with puts and save!" do
      text_proxy[:summary].puts "Line 1"
      text_proxy[:summary].puts "Line 2"
      text_proxy.save!(:summary)

      artifact = text_run.artifacts.find_by(name: "summary")
      expect(artifact.data_text).to eq("Line 1\nLine 2\n")
    end

    it "supports appending with << and save!" do
      text_proxy[:summary] << "a"
      text_proxy[:summary] << "b"
      text_proxy.save!(:summary)

      artifact = text_run.artifacts.find_by(name: "summary")
      expect(artifact.data_text).to eq("ab")
    end
  end
end
