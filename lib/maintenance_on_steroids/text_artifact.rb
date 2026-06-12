module MaintenanceOnSteroids
  class TextArtifact
    attr_reader :record

    delegate :to_s, to: :value

    def initialize(record)
      @record = record
      @value = record.data_text || ""
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
      @record.update!(data_text: @value)
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
