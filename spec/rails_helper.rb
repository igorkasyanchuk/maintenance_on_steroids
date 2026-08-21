ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"

require "rspec/rails"

# Load the schema into the test database. SQLite runs in memory, so this is
# per-process; Postgres needs the database created and any previous schema
# dropped first.
ActiveRecord::Schema.verbose = false
if ActiveRecord::Base.connection_db_config.adapter.to_s.include?("postgresql")
  ActiveRecord::Tasks::DatabaseTasks.create_current("test")
  ActiveRecord::Base.connection.tables.each do |table|
    ActiveRecord::Base.connection.drop_table(table, force: :cascade)
  end
end
load File.expand_path("dummy/db/schema.rb", __dir__)

# Load dummy app maintenance tasks
Dir[File.expand_path("dummy/app/maintenance/**/*.rb", __dir__)].each { |f| require f }

RSpec.configure do |config|
  config.fixture_paths = [Rails.root.join("spec/fixtures")]
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include Devise::Test::IntegrationHelpers, type: :request

  config.before(:each) do
    MaintenanceOnSteroids::JobRegistry.reset!
    [UpdateUsersTask, SimpleCallableTask, CsvExportTask, TaskWithQueue].each do |klass|
      MaintenanceOnSteroids::JobRegistry.register(klass)
    end

    # Disable auth in tests by default (individual specs can override)
    MaintenanceOnSteroids.http_basic_authentication_enabled = false
    MaintenanceOnSteroids.http_basic_authentication_user_name = MaintenanceOnSteroids::DEFAULT_HTTP_BASIC_USER_NAME
    MaintenanceOnSteroids.http_basic_authentication_password = MaintenanceOnSteroids::DEFAULT_HTTP_BASIC_PASSWORD
    MaintenanceOnSteroids.verify_access_proc = nil
    MaintenanceOnSteroids.authentication = nil
    MaintenanceOnSteroids.allow_insecure_dashboard = false
  end
end
