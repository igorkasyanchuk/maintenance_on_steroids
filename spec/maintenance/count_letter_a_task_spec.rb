require "rails_helper"

RSpec.describe CountLetterATask, type: :job do
  it "counts occurrences of the letter a in the uploaded file" do
    run = MaintenanceOnSteroids::Run.create!(task_class: "CountLetterATask", status: "enqueued")
    # File inputs arrive as a blob "input" artifact named after the form input.
    run.artifacts.create!(
      name: "file", kind: "input", artifact_type: "blob",
      data_blob: "id,name\n1,Alice\n2,Aaron\n", file_name: "people.csv"
    )

    MaintenanceOnSteroids::RunJob.perform_now(run.id)

    result = run.artifacts.find_by(name: "result", kind: "output").data_jsonb
    expect(result["a_lowercase"]).to eq("id,name\n1,Alice\n2,Aaron\n".count("a")) # 3
    expect(result["A_uppercase"]).to eq(2) # Alice, Aaron
    expect(result["total"]).to eq(result["a_lowercase"] + result["A_uppercase"])
    expect(result["file_name"]).to eq("people.csv")
    expect(run.reload.status).to eq("completed")
  end

  it "handles a missing file gracefully (zero counts)" do
    run = MaintenanceOnSteroids::Run.create!(task_class: "CountLetterATask", status: "enqueued")

    MaintenanceOnSteroids::RunJob.perform_now(run.id)

    result = run.artifacts.find_by(name: "result", kind: "output").data_jsonb
    expect(result["total"]).to eq(0)
    expect(run.reload.status).to eq("completed")
  end
end
