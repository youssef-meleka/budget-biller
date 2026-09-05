# frozen_string_literal: true

require "bigdecimal"
require_relative "errors"

module Billing
  # Immutable inputs/outputs for the pure core — no ActiveRecord, ever.
  BudgetSnapshot = Data.define(:id, :rate, :quota, :fill, :fallback_budget_id)
  Record         = Data.define(:date, :merchant_id, :channel, :engagements, :premium_engagements)
  Allocation     = Data.define(:budget_id, :engagements, :premium_engagements, :amount)

  class Allocator
    UNBILLED_BUDGET_ID = 0

    class << self
      # @param record            [Record]
      # @param budgets           [Hash{Integer => BudgetSnapshot}] already-locked values
      # @param primary_budget_id [Integer]
      # @return [Array<Allocation>] conserves record.engagements and
      #   record.premium_engagements exactly, each independently (I1, I2).
      def call(record:, budgets:, primary_budget_id:)
        remaining_engagements = record.engagements
        remaining_premium = record.premium_engagements
        allocations = []
        visited = []

        budget_id = primary_budget_id
        while remaining_engagements.positive? && budget_id && !visited.include?(budget_id)
          visited << budget_id
          budget = budgets[budget_id]
          break unless budget

          billed = affordable(budget, remaining_engagements)

          if billed.positive?
            premium_here = premium_for(remaining_premium:, engagements_billed: billed)
            allocations << Allocation.new(budget_id: budget.id, engagements: billed,
                                           premium_engagements: premium_here,
                                           amount: billed * budget.rate)
            remaining_engagements -= billed
            remaining_premium -= premium_here
          end

          budget_id = budget.fallback_budget_id
        end

        # (M1) Whatever the chain could not absorb — leftover engagements, leftover
        # premium, or both — becomes ONE bucket row, keeping I1 and I2 balanced.
        if remaining_engagements.positive? || remaining_premium.positive?
          allocations << Allocation.new(budget_id: UNBILLED_BUDGET_ID,
                                         engagements: remaining_engagements,
                                         premium_engagements: remaining_premium,
                                         amount: BigDecimal(0))
        end

        assert_conservation!(record, allocations)
        allocations
      end

      private

      def affordable(budget, wanted)
        return wanted if budget.rate.zero?

        capacity = budget.quota - budget.fill
        return 0 if capacity <= 0

        units = (capacity / budget.rate).floor
        [ units, wanted ].min
      end

      def premium_for(remaining_premium:, engagements_billed:)
        [ remaining_premium, engagements_billed ].min
      end

      def assert_conservation!(record, allocations)
        return if allocations.sum(&:engagements) == record.engagements &&
                  allocations.sum(&:premium_engagements) == record.premium_engagements

        raise Billing::ConservationViolation, "allocation lost or created engagements for #{record.inspect}"
      end
    end
  end
end
