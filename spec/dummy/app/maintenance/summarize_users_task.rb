class SummarizeUsersTask < MaintenanceOnSteroids::Task
  about do
    title "Summarize Users"
    description "Generates a text summary of all users"
    owner "Dev Team"
  end

  artifact :summary, type: :text

  def collection
    User.all
  end

  def process(user)
    artifacts[:summary].puts "User ##{user.id}: #{user.name} (#{user.email})"
    artifacts[:summary].save!
  end
end
