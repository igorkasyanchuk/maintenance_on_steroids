class UpdateUsersTask < MaintenanceOnSteroids::Task
  about do
    title "Update Users"
    description "Updates age for users matching a name"
    owner "Test Suite"
  end

  form do
    input :name, type: :string, required: true
    input :age, type: :integer, required: true
  end

  artifact :result, type: :jsonb, default: {}

  def collection
    User.where(name: params[:name]).order(id: :desc)
  end

  def process(user)
    user.update!(age: params[:age])
    artifacts[:result][user.id.to_s] = { user_id: user.id, age: user.age }
    artifacts[:result].save!
  end
end
