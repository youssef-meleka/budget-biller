# frozen_string_literal: true

module Billing
  class Reconcile
    # @param date        [Date]
    # @param merchant_id [String]
    # @param billing_run_id [String] the run about to write; rows NOT carrying
    #   it are by definition left over from an earlier run.
    # @return [Integer] how many stale rows were reversed and removed
    def self.call(date:, merchant_id:, billing_run_id:)
      stale = BilledStat.where(date:, merchant_id:).where.not(billing_run_id:)

      stale.group(:budget_id).sum(:amount).each do |budget_id, amount|
        next if budget_id == Billing::Allocator::UNBILLED_BUDGET_ID # never carried fill

        Budget.where(id: budget_id).update_all([ "fill = fill - ?", amount ])
      end

      stale.delete_all
    end
  end
end
