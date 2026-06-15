require "rails_helper"

RSpec.describe MaintenanceOnSteroids::ParamsProxy do
  let(:run) do
    MaintenanceOnSteroids::Run.create!(
      task_class: "UpdateUsersTask",
      status: "enqueued",
      params: { "name" => "Alice", "age" => "25" }
    )
  end

  let(:form_inputs) { UpdateUsersTask.form_inputs }

  subject { described_class.new(run, form_inputs) }

  describe "#[]" do
    it "returns string values" do
      expect(subject[:name]).to eq("Alice")
    end

    it "casts integer values" do
      expect(subject[:age]).to eq(25)
      expect(subject[:age]).to be_a(Integer)
    end

    it "returns nil for missing keys" do
      expect(subject[:missing]).to be_nil
    end

    it "falls back to the input's default when no value is stored" do
      inputs = [MaintenanceOnSteroids::FormDsl::InputDefinition.new(:limit, type: :integer, default: 100)]
      proxy = described_class.new(run, inputs)
      expect(proxy[:limit]).to eq(100)
    end

    it "prefers the stored value over the default" do
      inputs = [MaintenanceOnSteroids::FormDsl::InputDefinition.new(:age, type: :integer, default: 99)]
      proxy = described_class.new(run, inputs)
      expect(proxy[:age]).to eq(25)
    end

    it "returns nil for malformed date values instead of raising" do
      bad_run = MaintenanceOnSteroids::Run.create!(
        task_class: "UpdateUsersTask",
        status: "enqueued",
        params: { "starts_on" => "not-a-date", "starts_at" => "garbage" }
      )
      inputs = [
        MaintenanceOnSteroids::FormDsl::InputDefinition.new(:starts_on, type: :date),
        MaintenanceOnSteroids::FormDsl::InputDefinition.new(:starts_at, type: :datetime)
      ]
      proxy = described_class.new(bad_run, inputs)
      expect(proxy[:starts_on]).to be_nil
      expect(proxy[:starts_at]).to be_nil
    end

    it "parses valid date values" do
      date_run = MaintenanceOnSteroids::Run.create!(
        task_class: "UpdateUsersTask",
        status: "enqueued",
        params: { "starts_on" => "2026-06-12" }
      )
      inputs = [MaintenanceOnSteroids::FormDsl::InputDefinition.new(:starts_on, type: :date)]
      proxy = described_class.new(date_run, inputs)
      expect(proxy[:starts_on]).to eq(Date.new(2026, 6, 12))
    end

    context "with blob inputs" do
      let(:blob_inputs) { [MaintenanceOnSteroids::FormDsl::InputDefinition.new(:csv, type: :blob)] }
      let(:blob_proxy) { described_class.new(run, blob_inputs) }

      it "returns the stored input artifact data" do
        run.artifacts.create!(name: "csv", kind: "input", artifact_type: "blob", data_blob: "id,name\n1,Alice")
        expect(blob_proxy[:csv]).to eq("id,name\n1,Alice")
      end

      it "returns nil when no input artifact exists" do
        expect(blob_proxy[:csv]).to be_nil
      end

      it "memoizes blob lookups (single query per key)" do
        run.artifacts.create!(name: "csv", kind: "input", artifact_type: "blob", data_blob: "data")
        expect(blob_proxy[:csv]).to eq("data")

        queries = 0
        callback = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          expect(blob_proxy[:csv]).to eq("data")
        end
        expect(queries).to eq(0)
      end

      it "returns file_name and content_type from the uploaded artifact" do
        run.artifacts.create!(name: "csv", kind: "input", artifact_type: "blob",
                              data_blob: "x", file_name: "people.csv", content_type: "text/csv")
        expect(blob_proxy.file_name(:csv)).to eq("people.csv")
        expect(blob_proxy.content_type(:csv)).to eq("text/csv")
      end

      it "returns nil file_name/content_type when nothing was uploaded (cached)" do
        expect(blob_proxy.file_name(:csv)).to be_nil
        expect(blob_proxy.content_type(:csv)).to be_nil

        queries = 0
        callback = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          blob_proxy.file_name(:csv)
          blob_proxy.content_type(:csv)
        end
        expect(queries).to eq(0)
      end

      it "shares one query across [], file_name and content_type" do
        run.artifacts.create!(name: "csv", kind: "input", artifact_type: "blob",
                              data_blob: "x", file_name: "a.csv", content_type: "text/csv")
        blob_proxy[:csv] # primes the cache

        queries = 0
        callback = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          blob_proxy.file_name(:csv)
          blob_proxy.content_type(:csv)
        end
        expect(queries).to eq(0)
      end
    end
  end

  describe "#to_h" do
    it "returns the scalar params hash" do
      expect(subject.to_h).to eq({ "name" => "Alice", "age" => "25" })
    end
  end

  describe "#fetch" do
    it "returns value for existing key" do
      expect(subject.fetch(:name)).to eq("Alice")
    end

    it "returns default for missing key" do
      expect(subject.fetch(:missing, "default")).to eq("default")
    end

    it "raises KeyError when no default and key missing" do
      expect { subject.fetch(:missing) }.to raise_error(KeyError)
    end

    it "returns the block result for missing key" do
      expect(subject.fetch(:missing) { "from_block" }).to eq("from_block")
    end
  end
end
