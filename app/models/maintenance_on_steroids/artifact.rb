module MaintenanceOnSteroids
  class Artifact < ApplicationRecord
    belongs_to :run

    validates :name, presence: true
    validates :kind, inclusion: { in: %w[input output] }
    validates :artifact_type, inclusion: { in: %w[jsonb blob text] }

    def data
      case artifact_type
      when "jsonb" then data_jsonb
      when "blob"  then data_blob
      when "text"  then data_text
      end
    end

    def downloadable?
      artifact_type == "blob" && data_blob.present?
    end

    def display_value
      case artifact_type
      when "jsonb"
        data_jsonb.present? ? JSON.pretty_generate(data_jsonb) : "{}"
      when "text"
        data_text.to_s
      when "blob"
        if file_name.present?
          "#{file_name} (#{human_size})"
        else
          "Binary data (#{human_size})"
        end
      end
    end

    def human_size
      return "0 B" unless data_blob
      size = data_blob.bytesize
      if size < 1024
        "#{size} B"
      elsif size < 1024 * 1024
        "#{(size / 1024.0).round(1)} KB"
      else
        "#{(size / (1024.0 * 1024)).round(1)} MB"
      end
    end
  end
end
