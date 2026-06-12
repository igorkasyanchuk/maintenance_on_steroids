MaintenanceOnSteroids.configure do |config|
  # Resolve current user for tracking who triggered a run.
  # Receives the controller instance so Devise's current_user is available.
  config.current_user_resolver = ->(controller) {
    controller.current_user if controller.respond_to?(:current_user)
  }

  # Require signed-in admin to access maintenance tasks
  config.verify_access_proc = ->(controller) {
    user = controller.respond_to?(:current_user) && controller.current_user
    user&.admin?
  }

  # Redirect non-admins to sign in
  config.authentication = -> {
    unless current_user
      redirect_to main_app.new_user_session_path, alert: "Please sign in to continue."
    end
  }
end
