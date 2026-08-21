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
