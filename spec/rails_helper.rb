ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"

require "rspec/rails"

# Load schema into in-memory SQLite
ActiveRecord::Schema.verbose = false
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
    MaintenanceOnSteroids.verify_access_proc = nil
    MaintenanceOnSteroids.authentication = nil
  end
end
