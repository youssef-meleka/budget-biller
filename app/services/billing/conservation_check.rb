# frozen_string_literal: true

module Billing
  class ConservationCheck
    Violation = Data.define(:kind, :key, :expected, :actual)

    class << self
      def call
        engagements + premium + overfills + abandoned
      end

      # I1 — per date, across real budgets AND the unbilled bucket.
      def engagements
        compare(:engagements)
      end

      # I2 — the same, independently. Never derived from I1.
      def premium
        compare(:premium_engagements)
      end

      # I3
      def overfills
        Budget.where("fill > quota").map do |b|
          Violation.new(kind: :overfill, key: b.id, expected: b.quota, actual: b.fill)
        end
      end

      # (M3) A batch at MAX_ATTEMPTS is terminal
      def abandoned
        BillingBatch.where(state: "failed").map do |batch|
          scope = { date: batch.date, merchant_id: batch.merchant_id }

          Violation.new(kind: :abandoned,
                        key: [ batch.date, batch.merchant_id ],
                        expected: PendingEngagement.where(scope).sum(:engagements),
                        actual: BilledStat.where(scope).sum(:engagements))
        end
      end

      private

      # Only *settled* dates can be expected to balance. A date with staged
      # work that hasn't been billed yet — a fresh ingest, or a re-opened
      # batch whose re-bill hasn't run — is pending work, not a violation.
      #
      # (M3) 'failed' is deliberately excluded from that set. It is terminal, will
      # never be billed, and must not suppress its date's ledgers; #abandoned
      # reports it instead. Only genuinely in-flight work skips a date.
      def compare(column)
        settled = BillingBatch.where(state: "billed")
                              .where("billed_digest = staging_digest")
                              .pluck(:date, :merchant_id)
        in_flight_dates = BillingBatch.where(state: %w[pending claimed])
                                       .or(BillingBatch.where(state: "billed")
                                                        .where("billed_digest != staging_digest"))
                                       .pluck(:date).uniq
        billed_dates = settled.map(&:first).uniq - in_flight_dates
        return [] if billed_dates.empty?

        staged = PendingEngagement.where(date: billed_dates).group(:date).sum(column)
        billed = BilledStat.where(date: billed_dates).group(:date).sum(column)

        staged.filter_map do |date, expected|
          actual = billed.fetch(date, 0)
          Violation.new(kind: column, key: date, expected:, actual:) if actual != expected
        end
      end
    end
  end
end
