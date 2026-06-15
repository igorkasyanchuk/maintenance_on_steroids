require "rails_helper"

RSpec.describe MaintenanceOnSteroids::Instrumentation do
  def create_run(task_class: "SimpleCallableTask", status: "enqueued", params: {})
    MaintenanceOnSteroids::Run.create!(task_class: task_class, status: status, params: params)
  end

  def capture_events(name)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(name) do |event|
      events << event
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "emits enqueued.maintenance_on_steroids on enqueue!" do
    run = create_run
    events = capture_events("enqueued.maintenance_on_steroids") { run.enqueue! }

    expect(events.size).to eq(1)
    expect(events.first.payload[:run]).to eq(run)
    expect(events.first.payload[:task_name]).to eq("SimpleCallableTask")
  end

  it "emits started and succeeded around a successful run" do
    run = create_run
    started = nil
    succeeded = nil

    started = capture_events("started.maintenance_on_steroids") do
      succeeded = capture_events("succeeded.maintenance_on_steroids") do
        MaintenanceOnSteroids::RunJob.perform_now(run.id)
      end
    end

    expect(started.size).to eq(1)
    expect(succeeded.size).to eq(1)
    expect(succeeded.first.payload[:run].id).to eq(run.id)
  end

  it "emits errored with the exception when a run fails" do
    failing = Class.new(MaintenanceOnSteroids::Task) do
      def call = raise("boom")
    end
    stub_const("InstrumentationFailingTask", failing)
    MaintenanceOnSteroids::JobRegistry.register(failing)
    run = create_run(task_class: "InstrumentationFailingTask")

    events = capture_events("errored.maintenance_on_steroids") do
      expect { MaintenanceOnSteroids::RunJob.perform_now(run.id) }.to raise_error("boom")
    end

    expect(events.size).to eq(1)
    expect(events.first.payload[:error]).to be_a(RuntimeError)
    expect(events.first.payload[:task_name]).to eq("InstrumentationFailingTask")
  end

  it "emits paused exactly once when a run is paused mid-flight" do
    User.create!(name: "Bob", email: "pause-#{SecureRandom.hex(4)}@test.com", password: "password", active: true, age: 1)
    User.create!(name: "Bob", email: "pause-#{SecureRandom.hex(4)}@test.com", password: "password", active: true, age: 1)

    pausing = Class.new(MaintenanceOnSteroids::Task) do
      def collection = User.where(active: true)

      def process(_user)
        # Request a pause after the first record so check_status! pauses the run.
        MaintenanceOnSteroids::Run.where(id: run.id, status: "running").update_all(status: "pausing")
      end
    end
    stub_const("InstrumentationPausingTask", pausing)
    MaintenanceOnSteroids::JobRegistry.register(pausing)
    run = create_run(task_class: "InstrumentationPausingTask")

    events = capture_events("paused.maintenance_on_steroids") do
      MaintenanceOnSteroids::RunJob.perform_now(run.id)
    end

    expect(events.size).to eq(1)
    expect(events.first.payload[:run].id).to eq(run.id)
    expect(events.first.payload[:run].status).to eq("paused")
    expect(events.first.payload[:task_name]).to eq("InstrumentationPausingTask")
  end

  it "emits resumed (and enqueued) on resume!" do
    run = create_run(status: "paused")
    resumed = nil
    enqueued = nil

    resumed = capture_events("resumed.maintenance_on_steroids") do
      enqueued = capture_events("enqueued.maintenance_on_steroids") do
        run.resume!
      end
    end

    expect(resumed.size).to eq(1)
    expect(enqueued.size).to eq(1)
  end

  it "emits cancelled on direct cancel of an enqueued run" do
    run = create_run(status: "enqueued")
    events = capture_events("cancelled.maintenance_on_steroids") { run.cancel! }

    expect(events.size).to eq(1)
    expect(events.first.payload[:run].status).to eq("cancelled")
  end

  it "supports wildcard subscription to the whole namespace" do
    run = create_run(status: "enqueued")
    events = capture_events(/\.maintenance_on_steroids\z/) { run.cancel! }

    expect(events.map(&:name)).to eq(["cancelled.maintenance_on_steroids"])
  end
end
