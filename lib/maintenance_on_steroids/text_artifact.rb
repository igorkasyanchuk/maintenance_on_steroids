module MaintenanceOnSteroids
  class TextArtifact
    attr_reader :record

    delegate :to_s, to: :value

    def initialize(record)
      @record = record
      # dup so `<<`/`puts` don't mutate the record's own attribute string in
      # place (that would make dirty? always false and corrupt the record).
      @value = (record.data_text || "").dup
    end

    def value
      @value
    end

    # Append text
    def <<(text)
      @value << text.to_s
      self
    end

    # Append a line (adds newline)
    def puts(text = "")
      @value << text.to_s << "\n"
      self
    end

    # Replace all text
    def replace(text)
      @value = text.to_s
      self
    end

    def save!
      @record.data_text = @value
      @record.refresh_metadata!
      @record.save!
    end

    # True when buffered text differs from what's persisted. Lets the proxy
    # auto-flush only artifacts that were actually written.
    def dirty?
      @value != (@record.data_text || "")
    end

    def blank?
      @value.blank?
    end

    def present?
      @value.present?
    end

    def length
      @value.length
    end

    def ==(other)
      case other
      when TextArtifact then @value == other.value
      when String then @value == other
      else false
      end
    end

    def inspect
      "#<TextArtifact #{@value.truncate(60).inspect}>"
    end
  end
end
