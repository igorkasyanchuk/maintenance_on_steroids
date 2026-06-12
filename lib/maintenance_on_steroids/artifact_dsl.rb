module MaintenanceOnSteroids
  module ArtifactDsl
    extend ActiveSupport::Concern

    class ArtifactDefinition
      attr_reader :name, :type, :default, :file_name

      def initialize(name, type: :jsonb, default: nil, file_name: nil)
        @name      = name.to_sym
        @type      = type.to_sym
        @default   = default
        @file_name = file_name
      end

      # :file is stored as blob in the database
      def storage_type
        type == :file ? :blob : type
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
