module MaintenanceOnSteroids
  class ArtifactsProxy
    def initialize(run, artifact_definitions)
      @run = run
      @definitions = artifact_definitions.index_by(&:name)
      @cache = {}
    end

    def [](name)
      name = name.to_sym
      # key? rather than ||= : a :blob artifact wraps to the raw data_blob,
      # which is nil until something is written, and ||= would re-run the
      # find_by on every read -- once per record inside a collection task.
      return @cache[name] if @cache.key?(name)

      @cache[name] = load_artifact(name)
    end

    # Explicit, immediate persist of a full artifact value -- the primary write
    # API. The type is taken from the artifact declaration, so one call covers
    # every kind:
    #   artifacts.save(:json_data, { name: "Igor", age: 40 })  # jsonb
    #   artifacts.save(:export, rows)                           # csv (rows array or String)
    #   artifacts.save(:log, "done")                            # text
    # Returns the stored artifact wrapper. No auto-flush involved -- the write
    # happens now. (`artifacts[name] = value` is an alias.)
    def save(name, value)
      write_and_persist(name, value)
    end

    def []=(name, value)
      write_and_persist(name, value)
      value
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
      failure = nil
      @cache.each_pair do |name, cached|
        next unless cached.respond_to?(:dirty?) && cached.dirty?

        begin
          cached.save!
        rescue => e
          failure ||= e
          # One artifact failing to persist must not strand the others -- log
          # the declared name (always available) and keep flushing the rest.
          Rails.logger.error "[MaintenanceOnSteroids] Artifact flush error (#{name}): #{e.class}: #{e.message}"
        end
      end
      raise failure if failure
    end

    # Drop uncommitted buffers after a record/checkpoint transaction failed.
    def discard!
      @cache.clear
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

    # Shared write path for save / []=: write the value into the record,
    # persist immediately, and cache the wrapper. Handles the concurrent-create
    # race on the unique (run_id, name, kind) index.
    def write_and_persist(name, value)
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
        record.worker_token = @run.worker_token
        record.artifact_type = definition.storage_type.to_s
        write_value(record, definition, value)
        record.refresh_metadata!
        record.save!
      end
      @cache[name] = wrap(record, definition)
    end

    def load_artifact(name)
      definition = @definitions[name]
      return nil unless definition

      storage = definition.storage_type

      # Reads must not INSERT: build the record lazily and persist it only
      # on first save! / assignment. (update! on a new record saves it.)
      record = @run.artifacts.find_by(name: name.to_s, kind: "output")
      record ||= build_record(name, definition, storage)
      record.worker_token = @run.worker_token

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
        r.worker_token = @run.worker_token
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
