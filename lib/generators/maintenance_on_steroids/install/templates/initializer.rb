# Maintenance on Steroids
#
# The dashboard can start any task in app/maintenance/ against this database,
# so it needs access control before it goes anywhere near production. Configure
# at least one of the layers below -- in production the engine refuses to boot
# until you do.

MaintenanceOnSteroids.configure do |config|
  # --- Access control (pick at least one) -------------------------------

  # 1. HTTP Basic. Simplest option. The shipped password does NOT count as
  #    configured -- change it, and keep it out of version control.
  # config.http_basic_authentication_enabled   = true
  # config.http_basic_authentication_user_name = "admin"
  # config.http_basic_authentication_password  = Rails.application.credentials.maintenance_password

  # 2. Your app's own authentication. instance_exec'd in the controller, so
  #    Devise/Warden helpers are available.
  # config.authentication = -> { authenticate_user! }

  # 3. Authorization. Runs after the two above; returning false renders 403.
  #    An `authentication` hook alone only proves *who* the user is.
  # config.verify_access_proc = ->(controller) { controller.current_user&.admin? }

  # Already gated elsewhere (reverse proxy, VPN, middleware)? Say so
  # explicitly instead of leaving the layers above empty.
  # config.allow_insecure_dashboard = true

  # --- Optional ---------------------------------------------------------

  # Who triggered a run; must respond to #id (and optionally #email).
  # config.current_user_resolver = -> { Current.user }

  # How that user is displayed in the UI.
  # config.user_display_formatter = ->(run) { run.user_email }

  # Max size for file inputs uploaded when starting a run (read into memory).
  # config.max_upload_size = 50 * 1024 * 1024

  # Base controller for the engine's controllers, resolved at load time.
  # config.parent_controller = "ApplicationController"
end
