# frozen_string_literal: true

class BilledStat < ApplicationRecord
  validates :date, presence: true
  validates :merchant_id, presence: true
  validates :channel, presence: true
  validates :budget_id, presence: true
  validates :engagements, numericality: { greater_than_or_equal_to: 0 }
  validates :premium_engagements, numericality: { greater_than_or_equal_to: 0 }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
end
