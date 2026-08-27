# frozen_string_literal: true

class Budget < ApplicationRecord
  belongs_to :fallback_budget, class_name: "Budget", optional: true

  validates :merchant_id, presence: true
  validates :cost_model, presence: true, inclusion: { in: %w[CPC UEV] }
  validates :rate, numericality: { greater_than: 0 }
  validates :quota, numericality: { greater_than_or_equal_to: 0 }
  validates :fill, numericality: { greater_than_or_equal_to: 0 }
end
