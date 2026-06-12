require "rails_helper"

RSpec.describe "Authentication", type: :request do
  describe "verify_access_proc" do
    let!(:admin) { User.create!(email: "admin@test.com", password: "password", role: "admin") }
    let!(:user)  { User.create!(email: "user@test.com", password: "password", role: "user") }

    before do
      MaintenanceOnSteroids.verify_access_proc = ->(controller) {
        u = controller.respond_to?(:current_user) && controller.current_user
        u&.admin?
      }
      MaintenanceOnSteroids.authentication = -> {
        unless current_user
          redirect_to main_app.new_user_session_path, alert: "Please sign in."
        end
      }
    end

    it "allows admin access" do
      sign_in admin
      get "/maintenance"
      expect(response).to have_http_status(:success)
    end

    it "denies non-admin access" do
      sign_in user
      get "/maintenance"
      expect(response).to have_http_status(:forbidden)
    end

    it "redirects unauthenticated users" do
      get "/maintenance"
      expect(response).to redirect_to("/users/sign_in")
    end
  end

  describe "http_basic_authentication" do
    before do
      MaintenanceOnSteroids.http_basic_authentication_enabled = true
      MaintenanceOnSteroids.http_basic_authentication_user_name = "admin"
      MaintenanceOnSteroids.http_basic_authentication_password = "s3cret"
    end

    it "allows access with correct credentials" do
      get "/maintenance", headers: {
        "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("admin", "s3cret")
      }
      expect(response).to have_http_status(:success)
    end

    it "denies access with wrong credentials" do
      get "/maintenance", headers: {
        "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("admin", "wrong")
      }
      expect(response).to have_http_status(:unauthorized)
    end

    it "denies access without credentials" do
      get "/maintenance"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
