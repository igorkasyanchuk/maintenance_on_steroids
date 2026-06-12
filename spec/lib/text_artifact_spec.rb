require "rails_helper"

RSpec.describe MaintenanceOnSteroids::TextArtifact do
  let(:run) do
    MaintenanceOnSteroids::Run.create!(
      task_class: "SummarizeUsersTask",
      status: "running"
    )
  end

  let(:record) do
    run.artifacts.create!(
      name: "summary",
      kind: "output",
      artifact_type: "text",
      data_text: ""
    )
  end

  subject { described_class.new(record) }

  it "starts with empty text" do
    expect(subject.to_s).to eq("")
    expect(subject).to be_blank
  end

  it "appends text with <<" do
    subject << "Hello"
    subject << " World"
    expect(subject.to_s).to eq("Hello World")
  end

  it "appends lines with puts" do
    subject.puts "Line 1"
    subject.puts "Line 2"
    expect(subject.to_s).to eq("Line 1\nLine 2\n")
  end

  it "replaces text" do
    subject << "old"
    subject.replace("new")
    expect(subject.to_s).to eq("new")
  end

  it "persists on save!" do
    subject << "saved text"
    subject.save!

    reloaded = run.artifacts.find_by(name: "summary")
    expect(reloaded.data_text).to eq("saved text")
  end

  it "reports present? correctly" do
    expect(subject).not_to be_present
    subject << "x"
    expect(subject).to be_present
  end

  it "compares with strings" do
    subject << "hello"
    expect(subject).to eq("hello")
  end

  it "exposes the underlying record" do
    expect(subject.record).to eq(record)
  end
end
