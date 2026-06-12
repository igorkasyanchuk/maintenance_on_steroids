module MaintenanceOnSteroids
  class ArtifactsProxy
    def initialize(run, artifact_definitions)
      @run = run
      @definitions = artifact_definitions.index_by(&:name)
      @cache = {}
    end

    def [](name)
      name = name.to_sym
      @cache[name] ||= load_artifact(name)
    end

    def []=(name, value)
      name = name.to_sym
      definition = @definitions[name]
      raise ArgumentError, "Unknown artifact: #{name}" unless definition

      record = find_or_create_record(name, definition)
      write_value(record, definition, value)
      record.save!
      @cache[name] = wrap(record, definition)
    end

    def save!(name)
      name = name.to_sym
      cached = @cache[name]
      cached.save! if cached.respond_to?(:save!)
    end

    def save_all!
      @cache.each do |name, cached|
        save!(name)
      end
    end

    private

    def load_artifact(name)
      definition = @definitions[name]
      return nil unless definition

      storage = definition.storage_type

      record = @run.artifacts.find_by(name: name.to_s, kind: "output")
      unless record
        record = @run.artifacts.create!(
          name: name.to_s,
          kind: "output",
          artifact_type: storage.to_s,
          data_jsonb: storage == :jsonb ? (definition.default || {}) : nil,
          data_text: storage == :text ? (definition.default || "") : nil,
          data_blob: storage == :blob ? definition.default : nil,
          file_name: definition.file_name
        )
      end

      wrap(record, definition)
    end

    def find_or_create_record(name, definition)
      @run.artifacts.find_or_initialize_by(name: name.to_s, kind: "output").tap do |r|
        r.artifact_type = definition.storage_type.to_s
      end
    end

    def write_value(record, definition, value)
      case definition.storage_type
      when :jsonb
        record.data_jsonb = value.is_a?(Hash) ? value : { value: value }
      when :blob
        if value.respond_to?(:read)
          record.data_blob = value.read
          record.file_name ||= value.original_filename if value.respond_to?(:original_filename)
          record.content_type = value.content_type if value.respond_to?(:content_type)
        else
          record.data_blob = value
        end
        # Set file_name: explicit from DSL > already set > auto-generated default
        record.file_name ||= definition.file_name || default_file_name
      when :text
        record.data_text = value.to_s
      end
    end

    def wrap(record, definition)
      case definition.storage_type
      when :jsonb
        JsonbArtifact.new(record)
      when :text
        TextArtifact.new(record)
      when :blob
        record.data_blob
      end
    end

    def default_file_name
      task_class = @run.task_class.to_s.underscore.gsub("/", "_")
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
      "#{task_class}_#{timestamp}"
    end
  end
end
