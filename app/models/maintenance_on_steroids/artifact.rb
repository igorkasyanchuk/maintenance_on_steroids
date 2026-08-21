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

    # True when the inline preview shows less than the whole artifact -- either
    # because the payload is over the byte cap or because a jsonb document had
    # more than PREVIEW_ENTRIES top-level entries.
    def preview_truncated?
      return true if (byte_size || 0) > PREVIEW_BYTES

      jsonb_over_entry_cap?
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

    # Prefers the precomputed metadata byte count; falls back to measuring the
    # column that actually holds this type's payload. The old fallback only
    # looked at data_blob, so jsonb and text rows written before metadata
    # tracking reported nil -- which made preview_truncated? answer false and
    # bypassed every preview cap that depends on it.
    def byte_size
      metadata&.dig("bytes") || measured_byte_size
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

    # data_jsonb trimmed to PREVIEW_ENTRIES top-level entries. Driven by the
    # entry count itself rather than by preview_truncated?, so a row with no
    # recorded byte size still gets trimmed instead of being generated whole.
    # Scalars and small documents pass through untouched.
    def previewable_jsonb
      case data_jsonb
      when Hash  then data_jsonb.size > PREVIEW_ENTRIES ? data_jsonb.first(PREVIEW_ENTRIES).to_h : data_jsonb
      when Array then data_jsonb.size > PREVIEW_ENTRIES ? data_jsonb.first(PREVIEW_ENTRIES) : data_jsonb
      else data_jsonb
      end
    end

    def jsonb_over_entry_cap?
      artifact_type == "jsonb" &&
        data_jsonb.respond_to?(:size) &&
        !data_jsonb.is_a?(String) &&
        data_jsonb.size > PREVIEW_ENTRIES
    end

    def measured_byte_size
      case artifact_type
      when "jsonb"       then data_jsonb && data_jsonb.to_json.bytesize
      when "text"        then data_text&.bytesize
      when "blob", "csv" then data_blob&.bytesize
      end
    end

    # At most PREVIEW_BYTES of a payload, always returned as valid UTF-8, cut
    # back to the last complete line when it had to be truncated.
    #
    # Two encoding traps here, both of which used to reach the run page:
    #   - data_blob comes back as ASCII-8BIT, and interpolating a BINARY string
    #     holding non-ASCII bytes into the UTF-8 template raises
    #     Encoding::CompatibilityError -- so any CSV export containing an
    #     accented character took the page down, at any size.
    #   - byteslice cuts on a byte boundary, landing inside a multibyte
    #     character often enough to matter, and matching a Regexp against the
    #     resulting invalid string raises ArgumentError.
    # Slice first (bounded work), then transcode and scrub the small result.
    def preview_slice(content)
      truncated = content.bytesize > PREVIEW_BYTES
      sliced = truncated ? content.byteslice(0, PREVIEW_BYTES) : content

      sliced = sliced.dup.force_encoding(Encoding::UTF_8)
      sliced = sliced.scrub("") unless sliced.valid_encoding?

      return sliced unless truncated

      # Drop the trailing partial line -- but only when there is an earlier
      # newline to fall back to. A single-line payload (a minified blob, a log
      # with no line breaks) has no newline in the slice at all, and the regex
      # would match the whole thing and leave an empty preview.
      trimmed = sliced.sub(/[^\n]*\z/, "")
      trimmed.empty? ? sliced : trimmed
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
