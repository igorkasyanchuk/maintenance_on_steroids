module MaintenanceOnSteroids
  module FormDsl
    extend ActiveSupport::Concern

    class InputDefinition
      attr_reader :name, :type, :required, :default, :options, :label, :placeholder, :help_text

      def initialize(name, type: :string, required: false, default: nil, options: nil, label: nil, placeholder: nil, help_text: nil)
        @name        = name.to_sym
        @type        = type.to_sym
        @required    = required
        @default     = default
        @options     = options
        @label       = label || name.to_s.humanize
        @placeholder = placeholder
        @help_text   = help_text
      end

      def blob?
        type == :blob
      end

      def html_input_type
        case type
        when :string   then "text"
        when :integer  then "number"
        when :float    then "number"
        when :boolean  then "checkbox"
        when :text     then "textarea"
        when :date     then "date"
        when :datetime then "datetime-local"
        when :blob     then "file"
        when :select   then "select"
        else "text"
        end
      end
    end

    class FormBuilder
      attr_reader :inputs

      def initialize
        @inputs = []
      end

      def input(name, **options)
        @inputs << InputDefinition.new(name, **options)
      end
    end

    class_methods do
      def form(&block)
        builder = FormBuilder.new
        builder.instance_eval(&block)
        @form_inputs = builder.inputs
      end

      def form_inputs
        @form_inputs || []
      end
    end
  end
end
