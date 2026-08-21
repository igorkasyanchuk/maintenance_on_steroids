require "rails_helper"

RSpec.describe "per-task concurrency limit", type: :request do
  let!(:task_class) do
    klass = Class.new(MaintenanceOnSteroids::Task) do
      about { title "Exclusive Task" }
      job { concurrency 1 }
      def call; end
    end
    stub_const("ExclusiveTask", klass)
    MaintenanceOnSteroids::JobRegistry.register(klass)
    klass
  end

  def start
    post "/maintenance/jobs/ExclusiveTask/runs", params: { task_params: {} }
  end

  it "exposes the declared limit" do
    expect(ExclusiveTask.job_config.concurrency).to eq(1)
  end

  it "allows the first run" do
    expect { start }.to change { MaintenanceOnSteroids::Run.count }.by(1)
  end

  it "refuses a second run while one is active" do
    MaintenanceOnSteroids::Run.create!(task_class: "ExclusiveTask", status: "running", params: {})

    expect { start }.not_to change { MaintenanceOnSteroids::Run.count }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("already active")
  end

  it "allows a new run once the previous one is terminal" do
    MaintenanceOnSteroids::Run.create!(
      task_class: "ExclusiveTask", status: "completed", completed_at: Time.current, params: {}
    )

    expect { start }.to change { MaintenanceOnSteroids::Run.count }.by(1)
  end

  it "counts paused runs as active" do
    MaintenanceOnSteroids::Run.create!(task_class: "ExclusiveTask", status: "paused", params: {})

    expect { start }.not_to change { MaintenanceOnSteroids::Run.count }
  end

  it "does not constrain a task that declares no limit" do
    2.times { MaintenanceOnSteroids::Run.create!(task_class: "SimpleCallableTask", status: "running", params: {}) }

    expect {
      post "/maintenance/jobs/SimpleCallableTask/runs", params: { task_params: {} }
    }.to change { MaintenanceOnSteroids::Run.count }.by(1)
  end
end
