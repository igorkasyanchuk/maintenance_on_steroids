module MaintenanceOnSteroids
  class ParamsProxy
    def initialize(run, form_inputs)
      @run = run
      @form_inputs = form_inputs.index_by(&:name)
      @scalar_data = (run.params || {}).with_indifferent_access
    end

    def [](key)
      key = key.to_sym
      input = @form_inputs[key]

      if input&.blob?
        artifact = @run.artifacts.find_by(name: key.to_s, kind: "input")
        artifact&.data_blob
      else
        cast_value(@scalar_data[key], input&.type)
      end
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

    def cast_value(value, type)
      return value if value.nil?

      case type
      when :integer  then value.to_i
      when :float    then value.to_f
      when :boolean  then ActiveModel::Type::Boolean.new.cast(value)
      when :date     then value.is_a?(Date) ? value : Date.parse(value.to_s)
      when :datetime then value.is_a?(Time) ? value : Time.zone.parse(value.to_s)
      else value
      end
    end
  end
end
