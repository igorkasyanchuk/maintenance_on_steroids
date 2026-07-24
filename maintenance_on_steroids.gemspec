require_relative "lib/maintenance_on_steroids/version"

Gem::Specification.new do |spec|
  spec.name          = "maintenance_on_steroids"
  spec.version       = MaintenanceOnSteroids::VERSION
  spec.authors       = ["Igor Kasyanchuk"]
  spec.email         = ["igorkasyanchuk@gmail.com"]

  spec.summary       = "Maintenance tasks on steroids for Rails 8.1+"
  spec.description   = "A powerful maintenance task runner leveraging ActiveJob::Continuable. " \
                        "Features include: form inputs with typed parameters, DB-stored artifacts, " \
                        "database role switching, live progress UI, pause/resume/cancel, and more."
  spec.homepage      = "https://github.com/igorkasyanchuk/maintenance_on_steroids"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["source_code_uri"]        = spec.homepage
  spec.metadata["changelog_uri"]          = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]        = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"]  = "true"

  spec.files = Dir[
    "lib/**/*",
    "app/**/*",
    "config/**/*",
    "CHANGELOG.md",
    "LICENSE.txt",
    "README.md"
  ]

  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.1"
end
