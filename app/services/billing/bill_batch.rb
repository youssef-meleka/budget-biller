# frozen_string_literal: true

require "securerandom"
require_relative "allocator" # also pulls in errors.rb — both are Zeitwerk-ignored

module Billing
  class BillBatch
    MAX_DEADLOCK_RETRIES = 3

    class << self
      attr_accessor :race_hook
    end

    def self.call_next(worker_id:)
      batch = ClaimBatch.call(worker_id:)
      return :no_work unless batch

      Rails.logger.info(log_line("batch.claimed", batch, worker_id:, lease_expires_at: batch.lease_expires_at))

      begin
        bill!(batch, worker_id:)
        :billed
      rescue Billing::CapacityRaced => e
        Rails.logger.info(log_line("batch.capacity_raced", batch, worker_id:, error: e.message))
        :capacity_raced
      rescue Billing::LeaseLost
        Rails.logger.warn(log_line("batch.lease_lost", batch, worker_id:))
        :lease_lost
      rescue ActiveRecord::Deadlocked
        Rails.logger.warn(log_line("batch.deadlocked", batch, worker_id:))
        :deadlocked
      rescue ActiveRecord::RecordNotUnique
        Rails.logger.info(log_line("batch.already_billed", batch, worker_id:))
        batch.update!(state: "billed")
        :already_billed
      rescue Billing::Error, ActiveRecord::StatementInvalid => e
        Rails.logger.error(log_line("batch.failed", batch, worker_id:, error: e.message, class: e.class.name))
        batch.update!(state: "failed") if batch.attempts >= Billing::MAX_ATTEMPTS
        :failed
      end
    end

    def self.bill!(batch, worker_id:)
      attempts = 0
      begin
        bill_once!(batch, worker_id:)
      rescue ActiveRecord::Deadlocked
        attempts += 1
        raise if attempts > MAX_DEADLOCK_RETRIES

        sleep(0.05 * attempts * (1 + rand)) # jittered — un-synchronise the retriers
        retry
      end
    end
    private_class_method :bill!

    def self.bill_once!(batch, worker_id:)
      ActiveRecord::Base.transaction do
        # Lock in ascending id order to avoid deadlocking with concurrent workers locking the same budgets.
        budgets = Budget.where(merchant_id: batch.merchant_id).order(:id).lock.to_a
        raise Billing::MalformedBatch, "no budgets for merchant #{batch.merchant_id}" if budgets.empty?

        primary_budget_id = primary_budget_id_for(budgets)
        raise Billing::MalformedBatch, "no primary budget for merchant #{batch.merchant_id}" unless primary_budget_id

        records = PendingEngagement.where(date: batch.date, merchant_id: batch.merchant_id).order(:channel)
        raise Billing::MalformedBatch, "no staged rows for batch #{batch.id}" if records.empty?

        billing_run_id = SecureRandom.uuid

        reversed = Billing::Reconcile.call(date: batch.date, merchant_id: batch.merchant_id, billing_run_id:)

        # Snapshot only after the reversal has moved fill back.
        budgets.each(&:reload) if reversed.positive?
        snapshots = budgets.index_by(&:id).transform_values { |b| to_snapshot(b) }

        total_amount = BigDecimal(0)
        allocation_count = 0

        records.each do |staged|
          race_hook&.call

          record = Billing::Record.new(date: staged.date, merchant_id: staged.merchant_id, channel: staged.channel,
                                        engagements: staged.engagements, premium_engagements: staged.premium_engagements)
          allocations = Billing::Allocator.call(record:, budgets: snapshots, primary_budget_id:)

          allocations.each do |allocation|
            BilledStat.create!(date: staged.date, merchant_id: staged.merchant_id, channel: staged.channel,
                                budget_id: allocation.budget_id, engagements: allocation.engagements,
                                premium_engagements: allocation.premium_engagements, amount: allocation.amount,
                                billing_run_id:)
            allocation_count += 1

            next if allocation.budget_id == Billing::Allocator::UNBILLED_BUDGET_ID

            charge_budget!(allocation.budget_id, allocation.amount)
            snapshots[allocation.budget_id] = snapshots[allocation.budget_id].with(
              fill: snapshots[allocation.budget_id].fill + allocation.amount
            )
            total_amount += allocation.amount
          end
        end

        fence_commit!(batch:, worker_id:, billing_run_id:)

        Rails.logger.info(log_line("batch.billed", batch, worker_id:, allocations: allocation_count,
                                                            amount: total_amount, billing_run_id:,
                                                            reversed_rows: reversed))
      end
    end
    private_class_method :bill_once!

    # DB-side conditional UPDATE: the arithmetic and the quota guard happen
    # in one statement. Never `budget.fill += x`.
    def self.charge_budget!(budget_id, amount)
      rows = Budget.where(id: budget_id)
                    .where("fill + ? <= quota", amount)
                    .update_all([ "fill = fill + ?", amount ])

      raise Billing::CapacityRaced, "budget #{budget_id} capacity raced" if rows.zero?
    end
    private_class_method :charge_budget!

    def self.fence_commit!(batch:, worker_id:, billing_run_id:)
      updates = ActiveRecord::Base.sanitize_sql_array([
                                                         "state = 'billed', billed_digest = staging_digest, " \
                                                         "billed_at = NOW(), billing_run_id = ?", billing_run_id
                                                       ])
      fenced = BillingBatch.where(id: batch.id, claimed_by: worker_id, state: "claimed")
                            .where("lease_expires_at > NOW()")
                            .update_all(updates)

      raise Billing::LeaseLost, "lease lost for batch #{batch.id}" if fenced != 1
    end
    private_class_method :fence_commit!

    def self.primary_budget_id_for(budgets)
      fallback_targets = budgets.filter_map(&:fallback_budget_id)
      budgets.reject { |b| fallback_targets.include?(b.id) }.min_by(&:id)&.id
    end
    private_class_method :primary_budget_id_for

    def self.to_snapshot(budget)
      Billing::BudgetSnapshot.new(id: budget.id, rate: budget.rate, quota: budget.quota,
                                   fill: budget.fill, fallback_budget_id: budget.fallback_budget_id)
    end
    private_class_method :to_snapshot

    def self.log_line(event, batch, worker_id: nil, **extra)
      {
        event:,
        run_id:,
        worker_id: worker_id || batch&.claimed_by,
        date: batch&.date,
        merchant_id: batch&.merchant_id,
        attempts: batch&.attempts,
        **extra
      }.compact.to_json
    end
    private_class_method :log_line

    def self.run_id
      @run_id ||= SecureRandom.uuid
    end
  end
end
