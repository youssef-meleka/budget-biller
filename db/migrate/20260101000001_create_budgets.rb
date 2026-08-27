# frozen_string_literal: true

class CreateBudgets < ActiveRecord::Migration[7.2]
  def change
    create_table :budgets do |t|
      t.string  :merchant_id, null: false
      t.string  :cost_model,  null: false # CPC | UEV — metadata only, not used in allocation logic
      t.decimal :rate,        null: false, precision: 12, scale: 4
      t.decimal :quota,       null: false, precision: 14, scale: 2
      t.decimal :fill,        null: false, precision: 14, scale: 2, default: 0
      t.bigint  :fallback_budget_id # self-reference, nullable
      t.timestamps
    end

    add_index :budgets, :merchant_id
    add_foreign_key :budgets, :budgets, column: :fallback_budget_id

    # The I3 backstop. Any path that would overfill now fails loudly.
    add_check_constraint :budgets, "fill <= quota", name: "budgets_fill_within_quota"
    # Needed once reconciliation reverses fill.
    add_check_constraint :budgets, "fill >= 0",     name: "budgets_fill_non_negative"
    add_check_constraint :budgets, "rate > 0",      name: "budgets_rate_positive"
    add_check_constraint :budgets, "quota >= 0",    name: "budgets_quota_non_negative"
  end
end
