require "rails_helper"

RSpec.describe "select input validation", type: :request do
  let!(:task_class) do
    klass = Class.new(MaintenanceOnSteroids::Task) do
      about { title "Guarded Task" }
      form do
        input :mode, type: :select, options: %w[safe dry_run], required: true
        input :note, type: :string
      end

      def call; end
    end
    stub_const("GuardedTask", klass)
    MaintenanceOnSteroids::JobRegistry.register(klass)
    klass
  end

  def start(mode)
    post "/maintenance/jobs/GuardedTask/runs", params: { task_params: { mode: mode, note: "x" } }
  end

  it "starts a run for a declared option" do
    expect { start("dry_run") }.to change { MaintenanceOnSteroids::Run.count }.by(1)
    expect(MaintenanceOnSteroids::Run.last.params["mode"]).to eq("dry_run")
  end

  it "rejects a value that is not in the options" do
    expect { start("rm -rf") }.not_to change { MaintenanceOnSteroids::Run.count }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Invalid value for")
  end

  it "reports the missing-parameter error rather than the invalid one when blank" do
    expect { start("") }.not_to change { MaintenanceOnSteroids::Run.count }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Missing required parameters")
  end
end
