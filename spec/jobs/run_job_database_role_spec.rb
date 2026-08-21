require "rails_helper"

# `collection` returns a lazy Relation, so a role that is only held while the
# method runs is gone before a single row is fetched. RunJob must hold it for
# the whole scan, and step back to :writing for the run's own bookkeeping.
RSpec.describe "RunJob database_role", type: :job do
  # Records every connected_to(role:) the job opens, in order.
  def trace_roles
    roles = []
    allow(ActiveRecord::Base).to receive(:connected_to).and_wrap_original do |_original, **kwargs, &block|
      roles << kwargs[:role]
      block.call
    end
    yield
    roles
  end

  def create_users(count)
    count.times { |i| User.create!(name: "R#{i}", email: "role-#{i}@test.com", password: "password", active: true) }
  end

  def run_for(name)
    MaintenanceOnSteroids::Run.create!(task_class: name, status: "enqueued", params: {})
  end

  context "when a task declares one" do
    let!(:task_class) do
      klass = Class.new(MaintenanceOnSteroids::Task) do
        about { title "Replica Task" }
        job { database_role :read }

        def collection
          User.where(active: true)
        end

        def process(user)
          user.id
        end
      end
      stub_const("ReplicaTask", klass)
      MaintenanceOnSteroids::JobRegistry.register(klass)
      klass
    end

    it "normalizes the friendly alias" do
      expect(ReplicaTask.job_config.database_role).to eq(:reading)
    end

    it "holds the role across the scan and writes under :writing" do
      create_users(3)
      run = run_for("ReplicaTask")

      roles = trace_roles { MaintenanceOnSteroids::RunJob.perform_now(run.id) }

      expect(roles).to include(:reading)
      # One :writing per record, nested inside the open :reading scan.
      expect(roles.count(:writing)).to eq(3)
      expect(roles.first).to eq(:reading)
      expect(run.reload.status).to eq("completed")
      expect(run.progress_current).to eq(3)
    end
  end

  context "when a task declares none" do
    it "does not switch connections at all" do
      create_users(2)
      run = run_for("UpdateUsersTask")

      roles = trace_roles { MaintenanceOnSteroids::RunJob.perform_now(run.id) }

      expect(roles).to be_empty
      expect(run.reload.status).to eq("completed")
    end
  end
end

RSpec.describe "RunJob database_role scope", type: :job do
  it "does not wrap a callable task's body in the read role" do
    klass = Class.new(MaintenanceOnSteroids::Task) do
      about { title "Callable Replica Task" }
      job { database_role :reading }
      artifact :result, type: :jsonb, default: {}

      def call
        # A callable task is mostly writes; running this under :reading would
        # fail on a real replica.
        artifacts.save(:result, { "ok" => true })
      end
    end
    stub_const("CallableReplicaTask", klass)
    MaintenanceOnSteroids::JobRegistry.register(klass)

    run = MaintenanceOnSteroids::Run.create!(task_class: "CallableReplicaTask", status: "enqueued", params: {})

    roles = []
    allow(ActiveRecord::Base).to receive(:connected_to).and_wrap_original do |_o, **kw, &b|
      roles << kw[:role]
      b.call
    end

    MaintenanceOnSteroids::RunJob.perform_now(run.id)

    expect(roles).to be_empty
    expect(run.reload.status).to eq("completed")
    expect(run.artifacts.find_by(name: "result").data_jsonb).to eq("ok" => true)
  end

  it "reads job_config once per run, not once per record" do
    3.times { |i| User.create!(name: "C#{i}", email: "cfg-#{i}@test.com", password: "password", active: true) }
    run = MaintenanceOnSteroids::Run.create!(task_class: "UpdateUsersTask", status: "enqueued",
                                             params: { "name" => "C0", "age" => "5" })

    calls = 0
    allow(UpdateUsersTask).to receive(:job_config).and_wrap_original do |original|
      calls += 1
      original.call
    end

    MaintenanceOnSteroids::RunJob.perform_now(run.id)

    # Resolved once in #perform. job_config allocates a fresh JobConfig each
    # call when no `job` block is declared, so per-record reads meant one
    # throwaway object per record.
    expect(calls).to eq(1)
  end
end
