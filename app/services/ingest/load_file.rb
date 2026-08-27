# frozen_string_literal: true

require "csv"
require "digest"

module Ingest
  class LoadFile
    Result = Data.define(:file, :rows_read, :batches_touched)

    def self.call(path)
      new(path).call
    end

    def initialize(path)
      @path = path.to_s
    end

    def call
      rows = parse # all I/O happens before any write

      upsert_pending_engagements(rows)
      batch_keys = rows.map { |row| [ row[:date], row[:merchant_id] ] }.uniq
      touch_batches(batch_keys)

      Rails.logger.info({
        event: "ingest.completed", file: @path, rows: rows.size, batches: batch_keys.size
      }.to_json)

      Result.new(file: @path, rows_read: rows.size, batches_touched: batch_keys.size)
    end

    private

    # Every numeric field is BigDecimal/Integer, never Float.
    def parse
      CSV.foreach(@path, headers: true).map do |row|
        {
          date: Date.parse(row["date"]),
          merchant_id: row["merchant_id"].to_s,
          channel: row["channel"].to_s,
          engagements: Integer(row["engagements"]),
          premium_engagements: Integer(row["premium_engagements"])
        }
      end
    end

    # One statement for the whole file. ON CONFLICT resolves the race the
    # database sees; find_or_create_by would be a check-then-set.
    def upsert_pending_engagements(rows)
      now = Time.current
      records = rows.map do |row|
        row.merge(source_file: File.basename(@path), ingested_at: now, created_at: now, updated_at: now)
      end

      # Rails adds updated_at to the SET clause itself (record_timestamps) —
      # listing it in update_only too would assign the same column twice.
      PendingEngagement.upsert_all(
        records,
        unique_by: %i[date merchant_id channel],
        update_only: %i[engagements premium_engagements source_file ingested_at]
      )
    end

    def touch_batches(batch_keys)
      now = Time.current
      rows = batch_keys.map do |date, merchant_id|
        { date:, merchant_id:, state: "pending", attempts: 0,
          staging_digest: staging_digest_for(date, merchant_id),
          created_at: now, updated_at: now }
      end

      BillingBatch.upsert_all(rows, unique_by: %i[date merchant_id], update_only: %i[staging_digest])
    end

    def staging_digest_for(date, merchant_id)
      canonical = PendingEngagement.where(date:, merchant_id:)
                                    .order(:channel)
                                    .pluck(:channel, :engagements, :premium_engagements)

      Digest::SHA256.hexdigest(canonical.to_json)
    end
  end
end
