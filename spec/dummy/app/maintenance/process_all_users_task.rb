class ProcessAllUsersTask < MaintenanceOnSteroids::Task
  about do
    title "Process All Users"
    description "Iterates over all users with a 1-second delay per record"
    owner "Dev Team"
  end

  def collection
    User.all
  end

  def process(user)
    sleep 1
    Rails.logger.info "[ProcessAllUsersTask] Processed user ##{user.id}: #{user.name}"
  end
end
