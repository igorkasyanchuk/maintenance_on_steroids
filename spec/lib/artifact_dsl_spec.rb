require "rails_helper"

RSpec.describe MaintenanceOnSteroids::ArtifactDsl::ArtifactDefinition do
  it "raises on an unknown artifact type" do
    expect { described_class.new(:x, type: :json) }
      .to raise_error(ArgumentError, /Unknown artifact type :json/)
  end

  it "raises when the name collides with a reserved ArtifactsProxy method" do
    %i[save save! save_all! flush!].each do |reserved|
      expect { described_class.new(reserved) }
        .to raise_error(ArgumentError, /reserved/)
    end
  end

  it "accepts every valid type" do
    %i[jsonb file text csv].each do |t|
      expect { described_class.new(:x, type: t) }.not_to raise_error
    end
  end

  it "humanizes a default label and keeps an explicit one" do
    expect(described_class.new(:user_count).label).to eq("User count")
    expect(described_class.new(:user_count, label: "Total Users").label).to eq("Total Users")
  end

  it "stores description and headers" do
    defn = described_class.new(:report, type: :csv, headers: %w[a b], description: "desc")
    expect(defn.description).to eq("desc")
    expect(defn.headers).to eq(%w[a b])
  end

  describe "#storage_type" do
    it "maps :file to :blob and keeps :csv distinct" do
      expect(described_class.new(:x, type: :file).storage_type).to eq(:blob)
      expect(described_class.new(:x, type: :csv).storage_type).to eq(:csv)
      expect(described_class.new(:x, type: :jsonb).storage_type).to eq(:jsonb)
    end
  end

  describe "#resolved_content_type" do
    it "prefers an explicit content_type" do
      defn = described_class.new(:x, type: :file, file_name: "a.csv", content_type: "application/x-custom")
      expect(defn.resolved_content_type).to eq("application/x-custom")
    end

    it "infers from the file name extension" do
      expect(described_class.new(:x, type: :file, file_name: "report.pdf").resolved_content_type).to eq("application/pdf")
      expect(described_class.new(:x, type: :file, file_name: "data.csv").resolved_content_type).to eq("text/csv")
    end

    it "defaults csv to text/csv when no file name is known" do
      expect(described_class.new(:x, type: :csv).resolved_content_type).to eq("text/csv")
    end
  end
end
