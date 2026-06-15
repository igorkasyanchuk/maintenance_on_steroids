module MaintenanceOnSteroids
  class JsonbArtifact < HashWithIndifferentAccess
    # Accepts either an Artifact record (normal construction) or a plain
    # hash. HashWithIndifferentAccess internals (dup/merge/except/...) build
    # copies via `self.class.new(hash)`, so the hash form must be supported.
    # Such copies are "detached": they behave like hashes but cannot save!.
    def initialize(record_or_hash = {})
      if record_or_hash.respond_to?(:data_jsonb)
        @_record = record_or_hash
        super(record_or_hash.data_jsonb || {})
      else
        @_record = nil
        super(record_or_hash || {})
      end
    end

    def save!
      unless @_record
        raise "Cannot save! a detached JsonbArtifact copy (created via dup/merge/except). Save the original artifact instead."
      end

      @_record.data_jsonb = to_h
      @_record.refresh_metadata!
      @_record.save!
    end

    # True when the in-memory contents differ from what's persisted (or from
    # the lazy default for an unsaved record). Lets the proxy auto-flush only
    # artifacts that were actually written, avoiding phantom rows for reads.
    def dirty?
      return false unless @_record
      to_h != (@_record.data_jsonb || {})
    end

    def record
      @_record
    end
  end
end
