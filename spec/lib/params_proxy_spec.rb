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
  end
end
