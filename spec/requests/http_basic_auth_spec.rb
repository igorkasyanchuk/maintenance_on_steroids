require "rails_helper"

RSpec.describe "HTTP Basic authentication", type: :request do
  def get_dashboard(user = nil, password = nil)
    headers = {}
    if user
      headers["HTTP_AUTHORIZATION"] =
        ActionController::HttpAuthentication::Basic.encode_credentials(user, password.to_s)
    end
    get "/maintenance/dashboard", headers: headers
  end

  before { MaintenanceOnSteroids.http_basic_authentication_enabled = true }

  context "with a real password configured" do
    before { MaintenanceOnSteroids.http_basic_authentication_password = "a real secret" }

    it "allows the right credentials" do
      get_dashboard("admin", "a real secret")
      expect(response).to have_http_status(:ok)
    end

    it "challenges a wrong password" do
      get_dashboard("admin", "wrong")
      expect(response).to have_http_status(:unauthorized)
    end

    it "challenges a missing Authorization header" do
      get_dashboard
      expect(response).to have_http_status(:unauthorized)
    end
  end

  context "when the configured password is blank" do
    # e.g. Rails.application.credentials.maintenance_password with a missing key
    before { MaintenanceOnSteroids.http_basic_authentication_password = nil }

    it "denies an empty password rather than treating it as a match" do
      get_dashboard("admin", "")
      expect(response).to have_http_status(:forbidden)
    end

    it "denies every other attempt too" do
      get_dashboard("admin", "anything")
      expect(response).to have_http_status(:forbidden)

      get_dashboard
      expect(response).to have_http_status(:forbidden)
    end
  end
end
