if defined?(AnyLogin)
  AnyLogin.setup do |config|
    config.enabled = Rails.env.development?
    config.klass_name = "User"
    config.collection_method = :grouped_collection_by_role
    config.limit = 20
  end
end
