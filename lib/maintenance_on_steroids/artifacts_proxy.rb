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
      record.refresh_metadata!
      begin
        record.save!
      rescue ActiveRecord::RecordNotUnique
        # A concurrent writer created the row first (unique index on
        # run_id/name/kind) -- write into the existing record instead.
        record = @run.artifacts.find_by!(name: name.to_s, kind: "output")
        record.artifact_type = definition.storage_type.to_s
        write_value(record, definition, value)
        record.refresh_metadata!
        record.save!
      end
      @cache[name] = wrap(record, definition)
    end

    def save!(name)
      name = name.to_sym
      cached = @cache[name]
      cached.save! if cached.respond_to?(:save!)
    end

    def save_all!
      @cache.each_key { |name| save!(name) }
    end

    # Persists only artifacts whose in-memory contents were actually written
    # (dirty), so merely reading an artifact never creates a phantom row.
    # Called automatically by RunJob at completion and on pause/cancel.
    def flush!
      @cache.each_value do |cached|
        cached.save! if cached.respond_to?(:dirty?) && cached.dirty?
      end
    end

    # Method-style access for declared artifacts so call sites read naturally:
    #   artifacts.report << row      # instead of artifacts[:report] << row
    #   artifacts.result["k"] = v
    #   artifacts.summary = "..."
    def method_missing(method, *args)
      key = method.to_s.chomp("=").to_sym
      return super unless @definitions.key?(key)

      if method.to_s.end_with?("=")
        self[key] = args.first
      else
        self[key]
      end
    end

    def respond_to_missing?(method, include_private = false)
      @definitions.key?(method.to_s.chomp("=").to_sym) || super
    end

    private

    def load_artifact(name)
      definition = @definitions[name]
      return nil unless definition

      storage = definition.storage_type

      # Reads must not INSERT: build the record lazily and persist it only
      # on first save! / assignment. (update! on a new record saves it.)
      record = @run.artifacts.find_by(name: name.to_s, kind: "output")
      record ||= build_record(name, definition, storage)

      wrap(record, definition)
    end

    def build_record(name, definition, storage)
      record = @run.artifacts.new(
        name: name.to_s,
        kind: "output",
        artifact_type: storage.to_s,
        data_jsonb: storage == :jsonb ? (definition.default || {}) : nil,
        data_text: storage == :text ? (definition.default || "") : nil,
        data_blob: %i[blob csv].include?(storage) ? definition.default : nil,
        file_name: definition.file_name || definition.default_file_name
      )
      record.content_type = definition.resolved_content_type if storage == :csv
      record
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
        record.content_type ||= definition.resolved_content_type(record.file_name)
      when :csv
        record.data_blob = value.is_a?(String) ? value : render_csv(definition, value)
        record.file_name   ||= definition.file_name || definition.default_file_name
        record.content_type ||= definition.resolved_content_type || "text/csv"
      when :text
        record.data_text = value.to_s
      end
    end

    def render_csv(definition, rows)
      require "csv"
      CSV.generate do |csv|
        csv << definition.headers if definition.headers
        Array(rows).each { |row| csv << Array(row) }
      end
    end

    def wrap(record, definition)
      case definition.storage_type
      when :jsonb
        JsonbArtifact.new(record)
      when :text
        TextArtifact.new(record)
      when :csv
        CsvArtifact.new(record, headers: definition.headers)
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
