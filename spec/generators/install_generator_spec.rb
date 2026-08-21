require "rails_helper"
require "rails/generators"
require "generators/maintenance_on_steroids/install/install_generator"
require "fileutils"

RSpec.describe MaintenanceOnSteroids::Generators::InstallGenerator do
  let(:destination) { File.expand_path("../../tmp/generator", __dir__) }

  before do
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(File.join(destination, "config"))
    File.write(File.join(destination, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")

    # The generator's post-install `say` output would otherwise land in the
    # spec run. Swallow stdout for the duration, not the exceptions.
    original = $stdout
    $stdout = StringIO.new
    begin
      described_class.start([], destination_root: destination, behavior: :invoke, verbose: false)
    ensure
      $stdout = original
    end
  end

  after { FileUtils.rm_rf(destination) }

  def read(path)
    File.read(File.join(destination, path))
  end

  it "creates a migration that builds both tables" do
    migration = Dir[File.join(destination, "db/migrate/*_create_maintenance_on_steroids_tables.rb")].first
    expect(migration).to be_present

    content = File.read(migration)
    expect(content).to include("create_table :maintenance_on_steroids_runs")
    expect(content).to include("create_table :maintenance_on_steroids_artifacts")
    expect(content).to match(/ActiveRecord::Migration\[\d+\.\d+\]/)
  end

  it "creates the initializer, with access control front and centre" do
    initializer = read("config/initializers/maintenance_on_steroids.rb")

    expect(initializer).to include("MaintenanceOnSteroids.configure")
    expect(initializer).to include("http_basic_authentication_password")
    expect(initializer).to include("verify_access_proc")
    expect(initializer).to include("allow_insecure_dashboard")
  end

  it "mounts the engine and creates the tasks directory" do
    expect(read("config/routes.rb")).to include('mount MaintenanceOnSteroids::Engine, at: "/maintenance"')
    expect(File).to exist(File.join(destination, "app/maintenance/.keep"))
  end

  it "generates an initializer that is valid Ruby" do
    path = File.join(destination, "config/initializers/maintenance_on_steroids.rb")

    expect(system("ruby", "-c", path, out: File::NULL, err: File::NULL)).to be(true)
  end
end
