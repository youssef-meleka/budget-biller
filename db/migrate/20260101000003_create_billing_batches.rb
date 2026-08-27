# frozen_string_literal: true

class CreateBillingBatches < ActiveRecord::Migration[7.2]
  def change
    create_table :billing_batches do |t|
      t.date     :date,             null: false
      t.string   :merchant_id,      null: false
      t.string   :state,            null: false, default: "pending" # pending|claimed|billed|failed

      # staging_digest is recomputed by ingest; billed_digest is stamped on
      # commit. A batch is eligible iff state != 'failed' AND (state != 'billed'
      # OR staging_digest != billed_digest).
      t.string   :staging_digest,   null: false
      t.string   :billed_digest

      t.string   :claimed_by                     # worker identity
      t.datetime :claimed_at
      t.datetime :lease_expires_at                # crash recovery
      t.integer  :attempts,         null: false, default: 0 # poison-batch bound
      t.datetime :billed_at
      t.uuid     :billing_run_id                  # reconciliation stamp
      t.timestamps
    end

    add_index :billing_batches, %i[date merchant_id], unique: true

    # The claim query's predicate: state, plus expired leases. Index it — every poll hits it.
    add_index :billing_batches, %i[state lease_expires_at]

    add_check_constraint :billing_batches,
                          "state IN ('pending','claimed','billed','failed')",
                          name: "billing_batches_state_valid"
  end
end
