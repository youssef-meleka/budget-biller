# frozen_string_literal: true

module Billing
  class ConservationCheck
    Violation = Data.define(:kind, :key, :expected, :actual)

    class << self
      def call
        engagements + premium + overfills
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

      private

      # Only *settled* dates can be expected to balance. A date with staged
      # work that hasn't been billed yet — a fresh ingest, or a re-opened
      # batch whose re-bill hasn't run — is pending work, not a violation.
      def compare(column)
        settled = BillingBatch.where(state: "billed")
                              .where("billed_digest = staging_digest")
                              .pluck(:date, :merchant_id)
        unsettled_dates = BillingBatch.where.not(state: "billed")
                                       .or(BillingBatch.where("billed_digest != staging_digest"))
                                       .pluck(:date).uniq
        billed_dates = settled.map(&:first).uniq - unsettled_dates
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
