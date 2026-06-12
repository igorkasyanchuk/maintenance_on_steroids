module MaintenanceOnSteroids
  class JsonbArtifact < HashWithIndifferentAccess
    def initialize(record)
      @_record = record
      super(record.data_jsonb || {})
    end

    def save!
      @_record.update!(data_jsonb: to_h)
    end

    def record
      @_record
    end
  end
end
