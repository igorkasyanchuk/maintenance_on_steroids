require "rails_helper"

# The preview cap was previously covered by model specs only, so the view's
# truncated branch never rendered under test -- which is how a multibyte slice
# that raises ArgumentError reached the run page. These render the real view.
RSpec.describe "run page artifact previews", type: :request do
  let(:run) { MaintenanceOnSteroids::Run.create!(task_class: "CsvExportTask", status: "completed") }
  let(:cap) { MaintenanceOnSteroids::Artifact::PREVIEW_BYTES }

  def create_artifact(type, **attrs)
    run.artifacts.new(name: "a#{attrs.object_id}", kind: "output", artifact_type: type, **attrs)
       .tap { |a| a.refresh_metadata!; a.save! }
  end

  def show
    get "/maintenance/runs/#{run.id}"
  end

  it "renders an oversized text artifact whose cap boundary splits a multibyte character" do
    create_artifact("text", data_text: ("a" * (cap - 1)) + "…" + ("b" * 5_000))

    show

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Preview truncated")
  end

  it "renders an oversized CSV artifact with multibyte cells" do
    row = "#{'x' * 40},#{'ü' * 20}\n"
    create_artifact("csv", data_blob: row * ((cap / row.bytesize) + 50), file_name: "e.csv")

    show

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("download for the full file")
  end

  it "renders an oversized jsonb artifact and reports the truncation" do
    create_artifact("jsonb", data_jsonb: (1..5_000).to_h { |i| ["k#{i}", "v" * 100] })

    show

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Preview truncated")
  end

  it "renders a jsonb artifact with no recorded metadata" do
    # Legacy row: byte_size used to return nil here, so every cap was bypassed.
    run.artifacts.create!(
      name: "legacy", kind: "output", artifact_type: "jsonb",
      data_jsonb: (1..5_000).to_h { |i| ["k#{i}", "v" * 100] }, metadata: {}
    )

    show

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Preview truncated")
  end

  it "renders small artifacts of every type untruncated" do
    create_artifact("jsonb", data_jsonb: { "a" => 1 })
    create_artifact("text", data_text: "hello\n")
    create_artifact("csv", data_blob: "id,n\n1,a\n", file_name: "s.csv")

    show

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Preview truncated")
  end
end
