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

  describe "#save" do
    it "persists a jsonb value immediately and returns the wrapper" do
      result = nil
      expect { result = subject.save(:result, { "name" => "Igor", "age" => 40 }) }
        .to change(MaintenanceOnSteroids::Artifact, :count).by(1)
      expect(result).to be_a(MaintenanceOnSteroids::JsonbArtifact)
      expect(run.artifacts.find_by(name: "result").data_jsonb).to eq({ "name" => "Igor", "age" => 40 })
    end

    it "is equivalent to []= " do
      subject.save(:result, { "k" => "v" })
      expect(run.artifacts.find_by(name: "result").data_jsonb).to eq({ "k" => "v" })
    end

    it "raises for an undeclared artifact" do
      expect { subject.save(:nope, {}) }.to raise_error(ArgumentError, /Unknown artifact/)
    end
  end

  describe "#[]= return value" do
    it "returns the assigned value (Ruby assignment contract)" do
      expect(subject.send(:[]=, :result, { "k" => "v" })).to eq({ "k" => "v" })
    end
  end

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

  describe "#flush!" do
    it "persists dirty jsonb and text artifacts" do
      jsonb_defn = MaintenanceOnSteroids::ArtifactDsl::ArtifactDefinition.new(:result, type: :jsonb, default: {})
      text_defn = MaintenanceOnSteroids::ArtifactDsl::ArtifactDefinition.new(:summary, type: :text)
      proxy = described_class.new(run, [jsonb_defn, text_defn])

      proxy[:result]["foo"] = "bar"
      proxy[:summary] << "hello"

      expect { proxy.flush! }.to change(MaintenanceOnSteroids::Artifact, :count).by(2)
      expect(run.artifacts.find_by(name: "result").data_jsonb["foo"]).to eq("bar")
      expect(run.artifacts.find_by(name: "summary").data_text).to eq("hello")
    end

    it "does not create rows for artifacts that were only read (no phantom rows)" do
      proxy = described_class.new(run, definitions)
      proxy[:result] # read only, never written

      expect { proxy.flush! }.not_to change(MaintenanceOnSteroids::Artifact, :count)
    end

    it "keeps flushing the remaining artifacts when one save! raises" do
      jsonb_defn = MaintenanceOnSteroids::ArtifactDsl::ArtifactDefinition.new(:result, type: :jsonb, default: {})
      text_defn = MaintenanceOnSteroids::ArtifactDsl::ArtifactDefinition.new(:summary, type: :text)
      proxy = described_class.new(run, [jsonb_defn, text_defn])

      proxy[:result]["foo"] = "bar"
      proxy[:summary] << "hello"

      # First flushed artifact blows up on save!; the second must still persist.
      allow(proxy[:result]).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)

      expect { proxy.flush! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(run.artifacts.find_by(name: "summary").data_text).to eq("hello")
    end

    it "is a no-op when nothing was touched" do
      proxy = described_class.new(run, definitions)
      expect { proxy.flush! }.not_to change(MaintenanceOnSteroids::Artifact, :count)
    end
  end

  describe "metadata" do
    it "records entry count and byte size for jsonb on save" do
      subject[:result]["a"] = 1
      subject[:result]["b"] = 2
      subject.save!(:result)

      artifact = run.artifacts.find_by(name: "result")
      expect(artifact.metadata["entries"]).to eq(2)
      expect(artifact.metadata["bytes"]).to be > 0
      expect(artifact.metadata["generated_at"]).to be_present
    end

    it "records line count for text on save" do
      text_defn = MaintenanceOnSteroids::ArtifactDsl::ArtifactDefinition.new(:summary, type: :text)
      proxy = described_class.new(run, [text_defn])
      proxy[:summary].puts "one"
      proxy[:summary].puts "two"
      proxy.save!(:summary)

      expect(run.artifacts.find_by(name: "summary").metadata["lines"]).to eq(2)
    end

    it "records byte size for blob on assignment" do
      file_defn = MaintenanceOnSteroids::ArtifactDsl::ArtifactDefinition.new(:export, type: :file)
      proxy = described_class.new(run, [file_defn])
      proxy[:export] = "hello"

      expect(run.artifacts.find_by(name: "export").metadata["bytes"]).to eq(5)
    end
  end

  describe "method-style access" do
    it "reads a declared artifact via a reader method" do
      expect(subject.result).to be_a(MaintenanceOnSteroids::JsonbArtifact)
      expect(subject.result.object_id).to eq(subject[:result].object_id)
    end

    it "writes via a setter method" do
      subject.result = { "k" => "v" }
      expect(run.artifacts.find_by(name: "result").data_jsonb).to eq({ "k" => "v" })
    end

    it "still raises NoMethodError for undeclared names" do
      expect { subject.nope }.to raise_error(NoMethodError)
    end

    it "answers respond_to? for declared artifacts" do
      expect(subject.respond_to?(:result)).to be(true)
      expect(subject.respond_to?(:nope)).to be(false)
    end
  end

  describe "csv type artifacts" do
    let(:csv_run) { MaintenanceOnSteroids::Run.create!(task_class: "ExportProductsTask", status: "running") }
    let(:csv_proxy) { described_class.new(csv_run, ExportProductsTask.artifact_definitions) }

    it "returns a CsvArtifact on read" do
      expect(csv_proxy[:export]).to be_a(MaintenanceOnSteroids::CsvArtifact)
    end

    it "appends rows and auto-flushes to a downloadable csv" do
      csv_proxy[:export] << [1, "Alice", "SKU-1", 100, "draft"]
      csv_proxy.flush!

      record = csv_run.artifacts.find_by(name: "export")
      expect(record.artifact_type).to eq("csv")
      expect(record.file_name).to eq("export.csv")
      expect(record.content_type).to eq("text/csv")
      expect(record.data_blob).to include("id,name,sku,price_cents,status")
      expect(record).to be_downloadable
    end

    it "accepts a full array of rows via direct assignment" do
      csv_proxy[:export] = [[1, "Alice", "SKU-1", 100, "draft"]]
      record = csv_run.artifacts.find_by(name: "export")
      expect(record.data_blob).to eq("id,name,sku,price_cents,status\n1,Alice,SKU-1,100,draft\n")
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

RSpec.describe MaintenanceOnSteroids::ArtifactsProxy, "read caching" do
  let(:run) { MaintenanceOnSteroids::Run.create!(task_class: "CsvExportTask", status: "running") }

  # Counts real artifact loads only. Active Record tags its column/index
  # introspection as "SCHEMA", and whether that fires here depends on which
  # spec touched the model first -- counting it makes this assertion depend on
  # the random ordering seed.
  def artifact_queries
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if %w[SCHEMA CACHE TRANSACTION].include?(payload[:name])

      count += 1 if payload[:sql].to_s.include?("maintenance_on_steroids_artifacts")
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  it "does not re-query an unwritten blob artifact on every read" do
    definitions = [MaintenanceOnSteroids::ArtifactDsl::ArtifactDefinition.new(:doc, type: :file)]
    proxy = described_class.new(run, definitions)

    queries = artifact_queries { 3.times { proxy[:doc] } }

    expect(proxy[:doc]).to be_nil
    expect(queries).to eq(1)
  end
end
