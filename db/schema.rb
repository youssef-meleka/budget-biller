# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_01_01_000004) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "billed_stats", force: :cascade do |t|
    t.date "date", null: false
    t.string "merchant_id", null: false
    t.string "channel", null: false
    t.bigint "budget_id", null: false
    t.integer "engagements", null: false
    t.integer "premium_engagements", null: false
    t.decimal "amount", precision: 14, scale: 2, null: false
    t.uuid "billing_run_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["date", "merchant_id", "channel", "budget_id"], name: "idx_on_date_merchant_id_channel_budget_id_75850bb132", unique: true
    t.index ["date", "merchant_id"], name: "index_billed_stats_on_date_and_merchant_id"
    t.check_constraint "engagements >= 0 AND premium_engagements >= 0 AND amount >= 0::numeric", name: "billed_stats_non_negative"
  end

  create_table "billing_batches", force: :cascade do |t|
    t.date "date", null: false
    t.string "merchant_id", null: false
    t.string "state", default: "pending", null: false
    t.string "staging_digest", null: false
    t.string "billed_digest"
    t.string "claimed_by"
    t.datetime "claimed_at"
    t.datetime "lease_expires_at"
    t.integer "attempts", default: 0, null: false
    t.datetime "billed_at"
    t.uuid "billing_run_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["date", "merchant_id"], name: "index_billing_batches_on_date_and_merchant_id", unique: true
    t.index ["state", "lease_expires_at"], name: "index_billing_batches_on_state_and_lease_expires_at"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying, 'claimed'::character varying, 'billed'::character varying, 'failed'::character varying]::text[])", name: "billing_batches_state_valid"
  end

  create_table "budgets", force: :cascade do |t|
    t.string "merchant_id", null: false
    t.string "cost_model", null: false
    t.decimal "rate", precision: 12, scale: 4, null: false
    t.decimal "quota", precision: 14, scale: 2, null: false
    t.decimal "fill", precision: 14, scale: 2, default: "0.0", null: false
    t.bigint "fallback_budget_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["merchant_id"], name: "index_budgets_on_merchant_id"
    t.check_constraint "fill <= quota", name: "budgets_fill_within_quota"
    t.check_constraint "fill >= 0::numeric", name: "budgets_fill_non_negative"
    t.check_constraint "quota >= 0::numeric", name: "budgets_quota_non_negative"
    t.check_constraint "rate > 0::numeric", name: "budgets_rate_positive"
  end

  create_table "pending_engagements", force: :cascade do |t|
    t.date "date", null: false
    t.string "merchant_id", null: false
    t.string "channel", null: false
    t.integer "engagements", null: false
    t.integer "premium_engagements", null: false
    t.string "source_file", null: false
    t.datetime "ingested_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["date", "merchant_id", "channel"], name: "index_pending_engagements_on_date_and_merchant_id_and_channel", unique: true
    t.index ["date", "merchant_id"], name: "index_pending_engagements_on_date_and_merchant_id"
    t.check_constraint "engagements >= 0 AND premium_engagements >= 0", name: "pending_engagements_non_negative"
  end

  add_foreign_key "budgets", "budgets", column: "fallback_budget_id"
end
