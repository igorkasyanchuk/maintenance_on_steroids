require "rails_helper"

RSpec.describe "RunJob collection resumption", type: :model do
  # A task that records every processed user ID so we can verify no duplicates.
  let(:processed_ids) { [] }

  let!(:tracking_task_class) do
    ids = processed_ids
    Class.new(MaintenanceOnSteroids::Task) do
      @_processed_ids = ids

      about do
        title "Tracking Task"
      end

      artifact :result, type: :jsonb, default: {}

      def collection
        User.where(active: true)
      end

      def process(user)
        self.class.instance_variable_get(:@_processed_ids) << user.id
      end
    end
  end

  before do
    stub_const("TrackingTask", tracking_task_class)
    MaintenanceOnSteroids::JobRegistry.register(TrackingTask)
  end

  def create_users(count)
    count.times do |i|
      User.create!(
        name: "User #{i + 1}",
        email: "user#{i + 1}@test.com",
        password: "password",
        active: true
      )
    end
  end

  # Simulate what RunJob#process_collection does, but controlled:
  # Process records up to `stop_after` count, then save cursor and stop.
  def simulate_partial_run(run, task, stop_after:)
    collection = task.collection
    total = collection.count
    run.update!(status: "running", started_at: Time.current, progress_total: total)

    collection.unscope(:order).order(User.arel_table[:id].asc).limit(stop_after).each do |record|
      task.process(record)
      cursor_value = record.id
      run.update!(progress_current: run.progress_current + 1, cursor: cursor_value.to_s)
    end

    # Simulate pause
    run.update!(status: "paused")
  end

  # Simulate what RunJob#process_collection does on resume:
  # Uses the persisted cursor from the run to skip already-processed records.
  def simulate_resumed_run(run, task)
    collection = task.collection
    run.update!(status: "running")

    effective_cursor = run.cursor

    scope = if effective_cursor
              collection.unscope(:order).where(User.arel_table[:id].gt(effective_cursor))
            else
              collection.unscope(:order)
            end

    scope.order(User.arel_table[:id].asc).each do |record|
      task.process(record)
      cursor_value = record.id
      run.update!(progress_current: run.progress_current + 1, cursor: cursor_value.to_s)
    end

    run.update!(status: "completed", completed_at: Time.current)
  end

  it "does not process the same records twice after pause and resume" do
    create_users(10)
    all_user_ids = User.where(active: true).order(:id).pluck(:id)

    run = MaintenanceOnSteroids::Run.create!(
      task_class: "TrackingTask",
      status: "enqueued",
      params: {}
    )
    task = TrackingTask.new(run)

    # First run: process 5 users, then pause
    simulate_partial_run(run, task, stop_after: 5)

    expect(run.reload.status).to eq("paused")
    expect(run.cursor).to eq(all_user_ids[4].to_s) # cursor at 5th user's ID
    expect(run.progress_current).to eq(5)
    expect(processed_ids).to eq(all_user_ids.first(5))

    # Resume: process remaining users
    simulate_resumed_run(run, task)

    expect(run.reload.status).to eq("completed")
    expect(run.progress_current).to eq(10)

    # THE KEY ASSERTION: every user processed exactly once, no duplicates
    expect(processed_ids).to eq(all_user_ids)
    expect(processed_ids.uniq).to eq(processed_ids)
    expect(processed_ids.size).to eq(10)
  end

  it "does not process the same records twice after multiple pause/resume cycles" do
    create_users(10)
    all_user_ids = User.where(active: true).order(:id).pluck(:id)

    run = MaintenanceOnSteroids::Run.create!(
      task_class: "TrackingTask",
      status: "enqueued",
      params: {}
    )
    task = TrackingTask.new(run)

    # First run: process 3 users, then pause
    simulate_partial_run(run, task, stop_after: 3)
    expect(run.reload.progress_current).to eq(3)
    expect(processed_ids.size).to eq(3)

    # Second run: process 4 more users (3+4=7 total), then simulate another pause
    run.update!(status: "running")
    effective_cursor = run.cursor
    collection = task.collection
    scope = collection.unscope(:order).where(User.arel_table[:id].gt(effective_cursor))
    processed_this_round = 0
    scope.order(User.arel_table[:id].asc).each do |record|
      break if processed_this_round >= 4
      task.process(record)
      run.update!(progress_current: run.progress_current + 1, cursor: record.id.to_s)
      processed_this_round += 1
    end
    run.update!(status: "paused")

    expect(run.reload.progress_current).to eq(7)
    expect(processed_ids.size).to eq(7)

    # Third run: process remaining 3 users
    simulate_resumed_run(run, task)

    expect(run.reload.status).to eq("completed")
    expect(run.progress_current).to eq(10)

    # THE KEY ASSERTION: every user processed exactly once
    expect(processed_ids).to eq(all_user_ids)
    expect(processed_ids.uniq).to eq(processed_ids)
    expect(processed_ids.size).to eq(10)
  end

  it "processes all records from the start when there is no cursor" do
    create_users(5)
    all_user_ids = User.where(active: true).order(:id).pluck(:id)

    run = MaintenanceOnSteroids::Run.create!(
      task_class: "TrackingTask",
      status: "enqueued",
      params: {}
    )
    task = TrackingTask.new(run)

    # Run without any cursor (fresh run)
    expect(run.cursor).to be_nil

    simulate_resumed_run(run, task)

    expect(processed_ids).to eq(all_user_ids)
    expect(processed_ids.size).to eq(5)
  end

  it "persists cursor to the run record after each processed record" do
    create_users(3)
    user_ids = User.where(active: true).order(:id).pluck(:id)

    run = MaintenanceOnSteroids::Run.create!(
      task_class: "TrackingTask",
      status: "enqueued",
      params: {}
    )
    task = TrackingTask.new(run)

    simulate_partial_run(run, task, stop_after: 2)

    run.reload
    expect(run.cursor).to eq(user_ids[1].to_s)
    expect(run.progress_current).to eq(2)
  end
end
