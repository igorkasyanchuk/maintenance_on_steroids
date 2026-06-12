class SimpleCallableTask < MaintenanceOnSteroids::Task
  about do
    title "Simple Callable"
    description "A simple one-off task"
  end

  def call
    # Do something simple
    true
  end
end
