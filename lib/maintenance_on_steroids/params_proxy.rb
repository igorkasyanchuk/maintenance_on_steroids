module MaintenanceOnSteroids
  class ParamsProxy
    def initialize(run, form_inputs)
      @run = run
      @form_inputs = form_inputs.index_by(&:name)
      @scalar_data = (run.params || {}).with_indifferent_access
      @blob_cache = {}
    end

    def [](key)
      key = key.to_sym
      input = @form_inputs[key]

      if input&.blob?
        input_artifact(key)&.data_blob
      else
        value = @scalar_data[key]
        value = input.default if value.nil? && input
        cast_value(value, input&.type)
      end
    end

    # Original filename of an uploaded file input (nil if none uploaded).
    def file_name(key)
      input_artifact(key)&.file_name
    end

    # Declared MIME type of an uploaded file input (nil if none uploaded).
    def content_type(key)
      input_artifact(key)&.content_type
    end

    def to_h
      @scalar_data.to_h
    end

    def fetch(key, *args, &block)
      value = self[key]
      return value unless value.nil?

      if args.any?
        args.first
      elsif block
        block.call
      else
        raise KeyError, "key not found: #{key}"
      end
    end

    private

    # The "input" artifact backing a file input, looked up once and cached
    # (including a nil result, so a missing upload isn't re-queried).
    def input_artifact(key)
      key = key.to_sym
      return @blob_cache[key] if @blob_cache.key?(key)

      @blob_cache[key] = @run.artifacts.find_by(name: key.to_s, kind: "input")
    end

    def cast_value(value, type)
      return value if value.nil?

      case type
      when :integer  then value.to_i
      when :float    then value.to_f
      when :boolean  then ActiveModel::Type::Boolean.new.cast(value)
      when :date     then parse_date(value)
      when :datetime then parse_datetime(value)
      else value
      end
    end

    def parse_date(value)
      value.is_a?(Date) ? value : Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def parse_datetime(value)
      value.is_a?(Time) ? value : Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
