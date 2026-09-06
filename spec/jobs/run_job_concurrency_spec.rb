require "rails_helper"
require "timeout"

# Real connections/processes; the PostgreSQL CI job runs these. SQLite's default
# in-memory database is private to each connection and cannot exercise this.
RSpec.describe "RunJob worker concurrency", type: :job do
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  before do
    skip "requires PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"
    @runs = []
    @users = []
  end

  after do
    @runs&.each { |run| MaintenanceOnSteroids::Run.find_by(id: run.id)&.destroy! }
    @users&.each { |user| User.find_by(id: user.id)&.destroy! }
  end

  def create_run(task)
    MaintenanceOnSteroids::Run.create!(task_class: task).tap { |run| @runs << run }
  end

  it "admits only one of two deliveries on separate connections" do
    entered = Queue.new
    release = Queue.new
    calls = Queue.new
    stub_const("ConcurrentDeliveryTask", Class.new(MaintenanceOnSteroids::Task) do
      define_method(:call) do
        calls << true
        entered << true
        release.pop
      end
    end)
    run = create_run("ConcurrentDeliveryTask")
    execute = -> do
      ActiveRecord::Base.connection_pool.with_connection do
        job = MaintenanceOnSteroids::RunJob.new(run.id)
        job.job_id = "same-delivery"
        job.perform_now
      end
    end
    first = Thread.new { execute.call }
    Timeout.timeout(10) { entered.pop }
    second = Thread.new { execute.call }
    Timeout.timeout(10) { second.value }
    expect(calls.size).to eq(1)
    release << true
    Timeout.timeout(10) { first.value }
    expect(run.reload.status).to eq("completed")
  ensure
    2.times { release << true } if release
    [first, second].compact.each do |thread|
      thread.join(5)
      thread.kill if thread.alive?
    end
  end

  it "preserves checkpointed CSV rows through a SIGKILL and operator resume" do
    require_relative "../support/killed_export_worker"
    reader, writer = IO.pipe
    first = User.create!(email: "crash-#{SecureRandom.hex(6)}@test.com", password: "password", name: "First")
    second = User.create!(email: "crash-#{SecureRandom.hex(6)}@test.com", password: "password", name: "Second")
    @users.concat([first, second])
    ids = [first.id, second.id]
    run = create_run("KilledExportTask")
    run.update!(params: { ids: ids })
    # A fresh process is portable across libpq/OpenSSL implementations; forking
    # an already connected, multithreaded Ruby process is not safe on macOS.
    worker = File.expand_path("../support/killed_export_worker.rb", __dir__)
    child = Process.spawn({ "MOS_CRASH_WORKER" => "1", "RAILS_ENV" => "test" },
                          RbConfig.ruby, worker, run.id.to_s, out: writer, err: writer)
    writer.close
    expect(Timeout.timeout(10) { reader.gets }).to eq("checkpointed\n")
    Process.kill("KILL", child)
    Process.wait(child)
    child = nil
    expect(run.reload.cursor).to eq(first.id.to_s)
    expect(CSV.parse(run.artifacts.find_by!(name: "report").data_blob)).to eq([[first.id.to_s]])
    run.update_columns(updated_at: 2.hours.ago)
    MaintenanceOnSteroids::Run.reap_stale!
    run.resume!
    perform_enqueued_jobs
    expect(run.reload.status).to eq("completed")
    expect(CSV.parse(run.artifacts.find_by!(name: "report").data_blob)).to eq(ids.map { |id| [id.to_s] })
  ensure
    if child
      Process.kill("KILL", child) rescue Errno::ESRCH
      Process.wait(child) rescue Errno::ECHILD
    end
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end
end
