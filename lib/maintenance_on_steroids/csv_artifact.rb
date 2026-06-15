require "csv"

module MaintenanceOnSteroids
  # Append-oriented CSV artifact. Buffers rows in memory and renders them to
  # the record's data_blob on save. Rows are plain arrays:
  #
  #   artifacts[:report] << [user.id, user.name]
  #
  # Headers (when declared on the artifact) are written as the first line and
  # transparently skipped when reloading an existing CSV (e.g. on resume).
  class CsvArtifact
    attr_reader :record, :headers, :rows

    def initialize(record, headers: nil)
      @record  = record
      @headers = headers
      @rows    = []
      @dirty   = false

      if record.data_blob.present?
        # A corrupted/partially-written blob must not abort a resume -- start
        # from an empty buffer instead of raising through RunJob#perform.
        begin
          parsed = CSV.parse(record.data_blob)
          if @headers && parsed.first&.map(&:to_s) == @headers.map(&:to_s)
            parsed = parsed.drop(1)
          end
          @rows = parsed
        rescue CSV::MalformedCSVError => e
          # Resume must proceed, so start from an empty buffer -- but a later
          # append+save will overwrite the unparseable blob, so log how many
          # bytes are being discarded rather than losing them silently.
          Rails.logger.error "[MaintenanceOnSteroids] CSV artifact reload failed " \
                             "(#{record.name}, discarding #{record.data_blob.bytesize} bytes): #{e.message}"
          @rows = []
        end
      end
    end

    def <<(row)
      @rows << Array(row)
      @dirty = true
      self
    end
    alias add <<

    def size
      @rows.size
    end

    def blank?
      @rows.empty?
    end

    def present?
      !blank?
    end

    def to_csv
      CSV.generate do |csv|
        csv << @headers if @headers
        @rows.each { |row| csv << row }
      end
    end

    def save!
      @record.data_blob = to_csv
      @record.content_type ||= "text/csv"
      @record.refresh_metadata!
      @record.save!
      @dirty = false
      self
    end

    def dirty?
      @dirty
    end

    def inspect
      "#<MaintenanceOnSteroids::CsvArtifact rows=#{@rows.size}>"
    end
  end
end
