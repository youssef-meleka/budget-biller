# frozen_string_literal: true

require "spec_helper" # NOT rails_helper — no Rails needed; the allocator is pure.
require "bigdecimal"
require "date"
require_relative "../../../app/services/billing/allocator"

RSpec.describe Billing::Allocator do
  def budget(id:, rate:, quota:, fill: 0, fallback: nil)
    Billing::BudgetSnapshot.new(id:, rate: BigDecimal(rate.to_s), quota: BigDecimal(quota.to_s),
                                 fill: BigDecimal(fill.to_s), fallback_budget_id: fallback)
  end

  def record(engagements:, premium: 0)
    Billing::Record.new(date: Date.new(2026, 8, 20), merchant_id: "m1", channel: "web",
                         engagements:, premium_engagements: premium)
  end

  it "bills the whole record when capacity allows (exact fit)" do
    result = described_class.call(record: record(engagements: 10),
                                   budgets: { 1 => budget(id: 1, rate: 0.5, quota: 5) },
                                   primary_budget_id: 1)

    expect(result.map(&:budget_id)).to eq([ 1 ])
    expect(result.sum(&:amount)).to eq(BigDecimal("5.0"))
    expect(result.sum(&:engagements)).to eq(10)
  end

  it "bills exactly the capacity when engagements land one under the boundary" do
    # capacity 5 / rate 0.5 = exactly 10 affordable; 9 requested fits with room to spare
    result = described_class.call(record: record(engagements: 9),
                                   budgets: { 1 => budget(id: 1, rate: 0.5, quota: 5) },
                                   primary_budget_id: 1)

    expect(result.size).to eq(1)
    expect(result.first.engagements).to eq(9)
    expect(result.first.amount).to eq(BigDecimal("4.5"))
  end

  it "spills exactly one engagement over the boundary to the bucket when no fallback exists" do
    # capacity 5 / rate 0.5 = exactly 10 affordable; 11 requested spills 1
    result = described_class.call(record: record(engagements: 11),
                                   budgets: { 1 => budget(id: 1, rate: 0.5, quota: 5) },
                                   primary_budget_id: 1)

    primary = result.find { _1.budget_id == 1 }
    bucket = result.find { _1.budget_id == described_class::UNBILLED_BUDGET_ID }
    expect(primary.engagements).to eq(10)
    expect(bucket.engagements).to eq(1)
    expect(bucket.amount).to eq(0)
  end

  it "returns no allocation with a positive charge for zero engagements" do
    result = described_class.call(record: record(engagements: 0),
                                   budgets: { 1 => budget(id: 1, rate: 0.5, quota: 5) },
                                   primary_budget_id: 1)

    expect(result.sum(&:engagements)).to eq(0)
    expect(result.sum(&:premium_engagements)).to eq(0)
  end

  it "spills the remainder to the fallback at the fallback's own rate" do
    # primary fits 4 engagements (20 capacity / rate 5); 6 spill to budget 2
    budgets = {
      1 => budget(id: 1, rate: 5, quota: 20, fallback: 2),
      2 => budget(id: 2, rate: 1, quota: 100)
    }
    result = described_class.call(record: record(engagements: 10), budgets:, primary_budget_id: 1)

    expect(result.find { _1.budget_id == 1 }.engagements).to eq(4)
    expect(result.find { _1.budget_id == 2 }.engagements).to eq(6)
    expect(result.find { _1.budget_id == 2 }.amount).to eq(BigDecimal("6"))
  end

  it "sends the remainder to the unbilled bucket when no fallback exists" do
    result = described_class.call(record: record(engagements: 10),
                                   budgets: { 1 => budget(id: 1, rate: 5, quota: 20) },
                                   primary_budget_id: 1)

    bucket = result.find { _1.budget_id == described_class::UNBILLED_BUDGET_ID }
    expect(bucket.engagements).to eq(6)
    expect(bucket.amount).to eq(0)
  end

  it "sends the whole record to the bucket when the primary budget is already full" do
    result = described_class.call(record: record(engagements: 10),
                                   budgets: { 1 => budget(id: 1, rate: 5, quota: 20, fill: 20) },
                                   primary_budget_id: 1)

    expect(result.sum(&:engagements)).to eq(10)
    expect(result.map(&:budget_id).uniq).to eq([ described_class::UNBILLED_BUDGET_ID ])
  end

  it "walks a fallback chain of more than one hop" do
    budgets = {
      1 => budget(id: 1, rate: 1, quota: 2, fallback: 2),   # fits 2
      2 => budget(id: 2, rate: 1, quota: 3, fallback: 3),   # fits 3
      3 => budget(id: 3, rate: 1, quota: 100)               # absorbs the rest
    }
    result = described_class.call(record: record(engagements: 10), budgets:, primary_budget_id: 1)

    expect(result.find { _1.budget_id == 1 }.engagements).to eq(2)
    expect(result.find { _1.budget_id == 2 }.engagements).to eq(3)
    expect(result.find { _1.budget_id == 3 }.engagements).to eq(5)
  end

  it "sends the remainder to the bucket when the fallback is also full" do
    budgets = {
      1 => budget(id: 1, rate: 1, quota: 4, fallback: 2),
      2 => budget(id: 2, rate: 1, quota: 10, fill: 10) # fallback already full
    }
    result = described_class.call(record: record(engagements: 10), budgets:, primary_budget_id: 1)

    expect(result.find { _1.budget_id == 1 }.engagements).to eq(4)
    expect(result.find { _1.budget_id == described_class::UNBILLED_BUDGET_ID }.engagements).to eq(6)
  end

  it "affords zero engagements when the rate exceeds remaining capacity" do
    result = described_class.call(record: record(engagements: 5),
                                   budgets: { 1 => budget(id: 1, rate: 100, quota: 10) },
                                   primary_budget_id: 1)

    expect(result.map(&:budget_id).uniq).to eq([ described_class::UNBILLED_BUDGET_ID ])
    expect(result.size).to eq(1)
    expect(result.first.engagements).to eq(5)
  end

  it "guards rate == 0 as infinite capacity instead of raising ZeroDivisionError" do
    result = described_class.call(record: record(engagements: 5),
                                   budgets: { 1 => budget(id: 1, rate: 0, quota: 10) },
                                   primary_budget_id: 1)

    expect(result.size).to eq(1)
    expect(result.first.budget_id).to eq(1)
    expect(result.first.engagements).to eq(5)
    expect(result.first.amount).to eq(0)
  end

  it "splits premium exceeding what a real budget billed into the unbilled bucket (rule 9)" do
    # 500 engagements billed, 600 premium.
    result = described_class.call(record: record(engagements: 500, premium: 600),
                                   budgets: { 1 => budget(id: 1, rate: 0.05, quota: 30) },
                                   primary_budget_id: 1)

    real = result.find { _1.budget_id == 1 }
    bucket = result.find { _1.budget_id == described_class::UNBILLED_BUDGET_ID }

    expect(real.engagements).to eq(500)
    expect(real.premium_engagements).to eq(500)
    expect(bucket.engagements).to eq(0) # must be 0, not the billed count
    expect(bucket.premium_engagements).to eq(100)
    expect(bucket.amount).to eq(0)
  end

  it "drains premium fill-first when a single row splits across two budgets (§16.2)" do
    budgets = {
      1 => budget(id: 1, rate: 1, quota: 100, fallback: 2),
      2 => budget(id: 2, rate: 1, quota: 100)
    }
    result = described_class.call(record: record(engagements: 200, premium: 150), budgets:, primary_budget_id: 1)

    primary = result.find { _1.budget_id == 1 }
    fallback = result.find { _1.budget_id == 2 }

    expect(primary.engagements).to eq(100)
    expect(fallback.engagements).to eq(100)
    expect(primary.premium_engagements).to eq(100)
    expect(fallback.premium_engagements).to eq(50)
    expect(result.sum(&:premium_engagements)).to eq(150)
  end

  it "breaks a fallback cycle instead of looping forever" do
    budgets = {
      1 => budget(id: 1, rate: 1, quota: 1, fallback: 2),
      2 => budget(id: 2, rate: 1, quota: 1, fallback: 1) # cycles back to 1
    }
    result = described_class.call(record: record(engagements: 10), budgets:, primary_budget_id: 1)

    expect(result.sum(&:engagements)).to eq(10)
    expect(result.find { _1.budget_id == described_class::UNBILLED_BUDGET_ID }.engagements).to eq(8)
  end

  # Regression (M1).
  it "emits exactly one bucket row when engagements AND premium both overflow" do
    result = described_class.call(record: record(engagements: 11, premium: 20),
                                   budgets: { 1 => budget(id: 1, rate: 1, quota: 10) },
                                   primary_budget_id: 1)

    buckets = result.select { _1.budget_id == described_class::UNBILLED_BUDGET_ID }
    expect(buckets.size).to eq(1) # two would collide on the unique index

    expect(buckets.first.engagements).to eq(1)          # 11 wanted, 10 afforded
    expect(buckets.first.premium_engagements).to eq(10) # 20 carried, 10 rode along
    expect(buckets.first.amount).to eq(0)

    expect(result.sum(&:engagements)).to eq(11)
    expect(result.sum(&:premium_engagements)).to eq(20)
  end

  # I1 + I2 as a property of the pure function, over many shapes at once.
  it "conserves both ledgers for every input shape" do
    [ [ 0, 0 ], [ 1, 0 ], [ 10, 3 ], [ 10, 10 ], [ 999, 500 ] ].each do |engagements, premium|
      result = described_class.call(
        record: record(engagements:, premium:),
        budgets: { 1 => budget(id: 1, rate: 3, quota: 7, fallback: 2),
                   2 => budget(id: 2, rate: 2, quota: 5) },
        primary_budget_id: 1
      )
      expect(result.sum(&:engagements)).to eq(engagements)
      expect(result.sum(&:premium_engagements)).to eq(premium)
    end
  end
end
