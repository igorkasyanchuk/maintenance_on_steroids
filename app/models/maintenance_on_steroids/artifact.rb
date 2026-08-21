module MaintenanceOnSteroids
  class Artifact < ApplicationRecord
    belongs_to :run

    validates :name, presence: true
    validates :kind, inclusion: { in: %w[input output] }
    validates :artifact_type, inclusion: { in: %w[jsonb blob text csv] }

    # Cap on how much of an artifact is materialised for an in-page preview.
    # Parsing or HTML-escaping a payload costs several times its size in live
    # objects, so an uncapped preview of a large export OOMs the web process
    # to show the first hundred rows. The full payload is always downloadable.
    # ponytail: the column itself is still SELECTed whole -- if multi-hundred-MB
    # artifacts become normal, push the cap into SQL (substr) and out of Ruby.
    PREVIEW_BYTES = 256 * 1024

    # Top-level entries kept when previewing an oversized jsonb document.
    # Slicing generated JSON would mean generating all of it first, which is
    # exactly the allocation the byte cap exists to avoid -- so the structure
    # is trimmed before it is rendered, and the byte cap is a second backstop.
    PREVIEW_ENTRIES = 200

    def data
      case artifact_type
      when "jsonb"      then data_jsonb
      when "blob", "csv" then data_blob
      when "text"       then data_text
      end
    end

    def downloadable?
      %w[blob csv].include?(artifact_type) && data_blob.present?
    end

    # Parsed CSV rows for table preview, capped at PREVIEW_BYTES.
    # nil for non-CSV artifacts.
    def csv_rows
      return nil unless artifact_type == "csv" && data_blob.present?
      require "csv"
      CSV.parse(preview_slice(data_blob))
    rescue CSV::MalformedCSVError
      nil
    end

    # Capped textual content for inline display; nil for types with no
    # text preview (blob) or with nothing stored yet.
    def preview_text
      case artifact_type
      when "jsonb" then preview_slice(JSON.pretty_generate(previewable_jsonb)) if data_jsonb.present?
      when "text"  then preview_slice(data_text) if data_text.present?
      end
    end

    # True when the inline preview is showing less than the whole artifact.
    def preview_truncated?
      (byte_size || 0) > PREVIEW_BYTES
    end

    # Download attributes -- correct MIME and filename even for generated files
    # whose content_type wasn't set explicitly.
    def download_file_name
      file_name.presence || "#{name}.#{artifact_type == 'csv' ? 'csv' : 'bin'}"
    end

    def download_content_type
      content_type.presence ||
        Rack::Mime.mime_type(::File.extname(download_file_name), "application/octet-stream")
    end

    def display_value
      case artifact_type
      when "jsonb"
        data_jsonb.present? ? JSON.pretty_generate(data_jsonb) : "{}"
      when "text"
        data_text.to_s
      when "csv"
        data_blob.to_s
      when "blob"
        if file_name.present?
          "#{file_name} (#{human_size})"
        else
          "Binary data (#{human_size})"
        end
      end
    end

    # Recomputes lightweight stats (entry/line count, byte size, timestamp)
    # into the metadata column. Called on every artifact save so the UI can
    # show size/counts without loading the full payload.
    def refresh_metadata!
      self.metadata = (metadata || {}).merge(computed_metadata)
    end

    def computed_metadata
      base = { "generated_at" => Time.current.utc.iso8601 }
      case artifact_type
      when "jsonb"
        data = data_jsonb || {}
        base.merge("entries" => (data.respond_to?(:size) ? data.size : 1), "bytes" => data.to_json.bytesize)
      when "text"
        text = data_text || ""
        base.merge("lines" => text.lines.size, "bytes" => text.bytesize)
      when "csv"
        blob = data_blob || ""
        # Newline count == row count (CSV writes a trailing newline per row).
        base.merge("rows" => (blob.empty? ? 0 : blob.count("\n")), "bytes" => blob.bytesize)
      when "blob"
        base.merge("bytes" => (data_blob ? data_blob.bytesize : 0))
      else
        base
      end
    end

    # Prefers the precomputed metadata byte count; falls back to the blob
    # column for legacy rows saved before metadata tracking existed.
    def byte_size
      metadata&.dig("bytes") || data_blob&.bytesize
    end

    def generated_at
      ts = metadata&.dig("generated_at")
      Time.iso8601(ts) if ts.present?
    rescue ArgumentError
      nil
    end

    # One-line human summary for the UI: "12 entries · 3.4 KB" etc.
    def summary
      case artifact_type
      when "jsonb"
        "#{metadata&.dig('entries') || 0} entries · #{human_size}"
      when "text"
        "#{metadata&.dig('lines') || 0} lines · #{human_size}"
      when "csv"
        "#{metadata&.dig('rows') || 0} rows · #{human_size}"
      when "blob"
        file_name.present? ? "#{file_name} (#{human_size})" : "Binary data (#{human_size})"
      end
    end

    # data_jsonb trimmed to PREVIEW_ENTRIES top-level entries when it is over
    # the byte cap. Scalars and small documents pass through untouched.
    def previewable_jsonb
      return data_jsonb unless preview_truncated?

      case data_jsonb
      when Hash  then data_jsonb.first(PREVIEW_ENTRIES).to_h
      when Array then data_jsonb.first(PREVIEW_ENTRIES)
      else data_jsonb
      end
    end

    # First PREVIEW_BYTES of a payload, cut back to the last complete line so
    # a truncated slice still parses as CSV and doesn't end mid-character.
    def preview_slice(content)
      return content if content.bytesize <= PREVIEW_BYTES

      content.byteslice(0, PREVIEW_BYTES).sub(/[^\n]*\z/, "")
    end

    def human_size
      size = byte_size
      return "0 B" unless size && size.positive?
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
