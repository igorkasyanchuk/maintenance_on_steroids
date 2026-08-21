require "rails_helper"

RSpec.describe "Artifact download", type: :request do
  let(:run) { MaintenanceOnSteroids::Run.create!(task_class: "CsvExportTask", status: "completed") }

  def download(artifact)
    get "/maintenance/runs/#{run.id}/artifacts/#{artifact.id}/download"
  end

  it "sends a blob artifact" do
    artifact = run.artifacts.create!(
      name: "export", kind: "output", artifact_type: "csv",
      data_blob: "id,name\n1,Igor\n", file_name: "export.csv"
    )

    download(artifact)

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("id,name\n1,Igor\n")
    expect(response.headers["Content-Disposition"]).to include("export.csv")
  end

  it "404s a jsonb artifact instead of serving an empty .bin" do
    artifact = run.artifacts.create!(
      name: "result", kind: "output", artifact_type: "jsonb", data_jsonb: { "a" => 1 }
    )

    expect { download(artifact) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "does not serve an artifact belonging to another run" do
    other = MaintenanceOnSteroids::Run.create!(task_class: "CsvExportTask", status: "completed")
    artifact = other.artifacts.create!(
      name: "export", kind: "output", artifact_type: "csv", data_blob: "x\n"
    )

    expect { download(artifact) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
