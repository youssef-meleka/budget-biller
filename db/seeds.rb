# frozen_string_literal: true

# Idempotent — re-running must not duplicate rows or change the resulting
# fills. This is setup data, not part of the ingest pipeline.
require "csv"
require "bigdecimal"

rows = CSV.read(Rails.root.join("data/budgets.csv"), headers: true)

# Two passes: fallback_budget_id can reference a row not yet inserted (budget 1
# references budget 2, which comes later in the file), so set it only after
# every budget exists.
rows.each do |row|
  Budget.find_or_initialize_by(id: row["id"]).update!(
    merchant_id: row["merchant_id"],
    cost_model: row["cost_model"],
    rate: BigDecimal(row["rate"]),
    quota: BigDecimal(row["quota"]),
    fill: BigDecimal(row["fill"] || "0")
  )
end

rows.each do |row|
  next if row["fallback_budget_id"].blank?

  Budget.find(row["id"]).update!(fallback_budget_id: row["fallback_budget_id"])
end

# Sequence must be advanced past explicitly-set ids, or the next insert collides.
ActiveRecord::Base.connection.reset_pk_sequence!("budgets")
