# frozen_string_literal: true

class BillingBatch < ApplicationRecord
  enum :state, { pending: "pending", claimed: "claimed", billed: "billed", failed: "failed" },
       validate: true

  validates :date, presence: true
  validates :merchant_id, presence: true
  validates :staging_digest, presence: true
  validates :attempts, numericality: { greater_than_or_equal_to: 0 }

  scope :eligible, lambda {
    where.not(state: "failed")
         .where("state != 'billed' OR staging_digest != billed_digest")
  }
end
