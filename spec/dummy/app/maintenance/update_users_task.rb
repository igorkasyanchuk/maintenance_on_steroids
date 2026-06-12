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

  # Canonical artifact pattern: accumulate in memory per record, persist once
  # when the run finishes (saving the whole JSONB document per record is O(N^2)).
  after_complete :save_result

  def collection
    User.where(name: params[:name]).order(id: :desc)
  end

  def process(user)
    user.update!(age: params[:age])
    artifacts[:result][user.id.to_s] = { user_id: user.id, age: user.age }
  end

  private

  def save_result
    artifacts[:result].save!
  end
end
