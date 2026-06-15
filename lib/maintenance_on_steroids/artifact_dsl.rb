require "rack/mime"

module MaintenanceOnSteroids
  module ArtifactDsl
    extend ActiveSupport::Concern

    class ArtifactDefinition
      VALID_TYPES = %i[jsonb file text csv].freeze
      # Names that would collide with real ArtifactsProxy methods, breaking
      # method-style access (`artifacts.<name>`). Reject them at load time.
      RESERVED_NAMES = %i[save save! save_all! flush flush!].freeze

      attr_reader :name, :type, :default, :file_name, :label, :description, :headers, :content_type

      def initialize(name, type: :jsonb, default: nil, file_name: nil, label: nil,
                     description: nil, headers: nil, content_type: nil)
        @name = name.to_sym
        @type = type.to_sym
        unless VALID_TYPES.include?(@type)
          raise ArgumentError,
                "Unknown artifact type #{@type.inspect} for artifact #{@name.inspect}. " \
                "Valid types: #{VALID_TYPES.join(', ')}"
        end
        if RESERVED_NAMES.include?(@name)
          raise ArgumentError,
                "Artifact name #{@name.inspect} is reserved (conflicts with ArtifactsProxy##{@name}). " \
                "Choose a different name."
        end

        @default      = default
        @file_name    = file_name
        @label        = label || name.to_s.humanize
        @description  = description
        @headers      = headers
        @content_type = content_type
      end

      # DB artifact_type / which data_* column the value is stored in.
      # :file is a friendly alias for binary blob storage; :csv keeps a
      # distinct artifact_type (its bytes live in data_blob) so the UI can
      # offer a table preview and a correctly-typed download.
      def storage_type
        type == :file ? :blob : type
      end

      # Resolved MIME type for downloads: explicit content_type wins, then
      # inference from the file name extension, then a per-type default.
      def resolved_content_type(fallback_file_name = nil)
        return @content_type if @content_type.present?

        name = file_name || fallback_file_name
        return "text/csv" if type == :csv && name.blank?
        return nil if name.blank?

        Rack::Mime.mime_type(::File.extname(name), nil)
      end

      def default_file_name
        type == :csv ? "#{name}.csv" : nil
      end
    end

    class_methods do
      def artifact(name, **options)
        @artifact_definitions ||= []
        @artifact_definitions << ArtifactDefinition.new(name, **options)
      end

      def artifact_definitions
        @artifact_definitions || []
      end
    end
  end
end
