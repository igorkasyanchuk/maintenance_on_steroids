module MaintenanceOnSteroids
  class Configuration
    attr_accessor :parent_controller
    attr_accessor :tasks_module

    def initialize
      @parent_controller = "ActionController::Base"
      @tasks_module = nil
    end
  end
end
