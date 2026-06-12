module MaintenanceOnSteroids
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
    self.table_name_prefix = "maintenance_on_steroids_"
  end
end
