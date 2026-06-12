class TaskWithQueue < MaintenanceOnSteroids::Task
  job do
    queue "exports"
  end

  about do
    title "Queued Task"
    description "Task with custom queue"
    owner "John Doe"
  end

  def call
    true
  end
end
