# frozen_string_literal: true

class CreatePendingEngagements < ActiveRecord::Migration[7.2]
  def change
    create_table :pending_engagements do |t|
      t.date     :date,                null: false
      t.string   :merchant_id,         null: false
      t.string   :channel,             null: false
      t.integer  :engagements,         null: false
      t.integer  :premium_engagements, null: false
      t.string   :source_file,         null: false # provenance
      t.datetime :ingested_at,         null: false
      t.timestamps
    end

    # THE ingest idempotency guarantee. upsert_all(unique_by:) requires this index to exist.
    add_index :pending_engagements, %i[date merchant_id channel], unique: true
    add_index :pending_engagements, %i[date merchant_id] # the batch lookup

    add_check_constraint :pending_engagements,
                          "engagements >= 0 AND premium_engagements >= 0",
                          name: "pending_engagements_non_negative"
  end
end
