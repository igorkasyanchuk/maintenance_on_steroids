require "rails_helper"

RSpec.describe "MaintenanceOnSteroids.verify_access_control!" do
  let(:logger) { Logger.new(buffer) }
  let(:buffer) { StringIO.new }
  let(:production) { ActiveSupport::StringInquirer.new("production") }
  let(:development) { ActiveSupport::StringInquirer.new("development") }

  def verify(env: development)
    MaintenanceOnSteroids.verify_access_control!(logger: logger, env: env)
  end

  after { MaintenanceOnSteroids.allow_insecure_dashboard = false }

  describe "#access_control_configured?" do
    it "is false when nothing is set" do
      expect(MaintenanceOnSteroids.access_control_configured?).to be(false)
    end

    it "is false when HTTP Basic still uses the shipped default password" do
      MaintenanceOnSteroids.http_basic_authentication_enabled = true

      expect(MaintenanceOnSteroids.http_basic_authentication_password)
        .to eq(MaintenanceOnSteroids::DEFAULT_HTTP_BASIC_PASSWORD)
      expect(MaintenanceOnSteroids.access_control_configured?).to be(false)
    end

    it "is false when only the Basic username was changed" do
      MaintenanceOnSteroids.http_basic_authentication_enabled = true
      MaintenanceOnSteroids.http_basic_authentication_user_name = "ops"

      expect(MaintenanceOnSteroids.access_control_configured?).to be(false)
    end

    it "is true once the Basic password is changed" do
      MaintenanceOnSteroids.http_basic_authentication_enabled = true
      MaintenanceOnSteroids.http_basic_authentication_password = "a real secret"

      expect(MaintenanceOnSteroids.access_control_configured?).to be(true)
    end

    it "is true for verify_access_proc or an authentication hook" do
      MaintenanceOnSteroids.verify_access_proc = ->(_c) { true }
      expect(MaintenanceOnSteroids.access_control_configured?).to be(true)

      MaintenanceOnSteroids.verify_access_proc = nil
      MaintenanceOnSteroids.authentication = -> {}
      expect(MaintenanceOnSteroids.access_control_configured?).to be(true)
    end
  end

  describe "in production" do
    it "refuses to boot when nothing is configured" do
      expect { verify(env: production) }
        .to raise_error(MaintenanceOnSteroids::InsecureDashboardError, /no access control is configured/)
    end

    it "refuses to boot when Basic still uses the default password" do
      MaintenanceOnSteroids.http_basic_authentication_enabled = true

      expect { verify(env: production) }
        .to raise_error(MaintenanceOnSteroids::InsecureDashboardError, /shipped default password/)
    end

    it "boots when the host explicitly opts out" do
      MaintenanceOnSteroids.allow_insecure_dashboard = true

      expect { verify(env: production) }.not_to raise_error
      expect(buffer.string).to match(/no access control is configured/)
    end

    it "boots once a layer is configured" do
      MaintenanceOnSteroids.verify_access_proc = ->(_c) { true }

      expect { verify(env: production) }.not_to raise_error
      expect(buffer.string).to be_empty
    end
  end

  describe "outside production" do
    it "warns instead of raising" do
      expect { verify }.not_to raise_error
      expect(buffer.string).to match(/no access control is configured/)
    end

    it "still warns about an authentication hook with no authorization" do
      MaintenanceOnSteroids.authentication = -> {}

      verify

      expect(buffer.string).to match(/without `verify_access_proc`/)
    end

    it "stays quiet when both layers are set" do
      MaintenanceOnSteroids.authentication = -> {}
      MaintenanceOnSteroids.verify_access_proc = ->(_c) { true }

      verify

      expect(buffer.string).to be_empty
    end
  end
end
