# frozen_string_literal: true

class CreateBilledStats < ActiveRecord::Migration[7.2]
  def change
    create_table :billed_stats do |t|
      t.date    :date,                 null: false
      t.string  :merchant_id,          null: false
      t.string  :channel,              null: false
      t.bigint  :budget_id,            null: false # 0 = unbilled bucket. NO FK — see below.
      t.integer :engagements,          null: false
      t.integer :premium_engagements,  null: false
      t.decimal :amount,               null: false, precision: 14, scale: 2
      t.uuid    :billing_run_id                    # which run wrote this row (Tier 3)
      t.timestamps
    end

    # THE billing idempotency guarantee. A second worker billing the same batch
    # hits this and rolls back instead of double-billing.
    add_index :billed_stats, %i[date merchant_id channel budget_id], unique: true
    add_index :billed_stats, %i[date merchant_id]

    add_check_constraint :billed_stats,
                          "engagements >= 0 AND premium_engagements >= 0 AND amount >= 0",
                          name: "billed_stats_non_negative"

    # No FK on budget_id: budget_id = 0 is the sentinel for the unbilled
    # bucket, but budgets.id is a bigint sequence starting at 1, so a FK would
    # reject every bucket row. The lost referential integrity is checked
    # instead by a spec (see worked_examples_spec.rb).
  end
end
