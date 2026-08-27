# frozen_string_literal: true

require "rails_helper"

# Numbers below are taken from the documented worked examples, not derived
# from the implementation.
RSpec.describe "the worked examples", type: :model do
  def seed_budgets!
    b1 = Budget.create!(id: 1, merchant_id: "100", cost_model: "CPC", rate: BigDecimal("0.10"),
                        quota: BigDecimal("50.00"), fill: 0)
    Budget.create!(id: 2, merchant_id: "100", cost_model: "CPC", rate: BigDecimal("0.08"),
                    quota: BigDecimal("20.00"), fill: 0)
    Budget.create!(id: 3, merchant_id: "200", cost_model: "UEV", rate: BigDecimal("0.05"),
                    quota: BigDecimal("30.00"), fill: 0)
    b1.update!(fallback_budget_id: 2)
  end

  def drain!
    loop { break if Billing::BillBatch.call_next(worker_id: "acceptance") == :no_work }
  end

  def fills
    Budget.order(:id).pluck(:fill)
  end

  def rows_for(date)
    BilledStat.where(date:).order(:merchant_id, :channel, :budget_id)
              .pluck(:merchant_id, :channel, :budget_id, :engagements, :premium_engagements, :amount)
  end

  before { seed_budgets! }

  it "reproduces file 1 exactly: the billed rows and the resulting fills" do
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20.csv"))
    drain!

    # Row 2 spills its remainder to fallback B2 once B1 fills exactly; row
    # 3's premium (600) exceeds its 500 billed engagements, sending 100
    # premium to the unbilled bucket.
    expect(rows_for(Date.new(2026, 8, 20))).to eq([
                                                     [ "100", "app", 1, 400, 100, BigDecimal("40.00") ],
                                                     [ "100", "web", 1, 100, 0, BigDecimal("10.00") ],
                                                     [ "100", "web", 2, 100, 0, BigDecimal("8.00") ],
                                                     [ "200", "app", 0, 0, 100, BigDecimal("0.00") ],
                                                     [ "200", "app", 3, 500, 500, BigDecimal("25.00") ]
                                                   ])

    expect(fills).to eq([ BigDecimal("50.00"), BigDecimal("8.00"), BigDecimal("25.00") ])
  end

  it "reproduces file 2 exactly, billed after file 1" do
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20.csv"))
    drain!
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-21.csv"))
    drain!

    # B1 is already full, so row 1's whole 150 falls to B2, taking it to
    # exactly 20.00.
    expect(rows_for(Date.new(2026, 8, 21))).to eq([
                                                     [ "100", "app", 2, 150, 0, BigDecimal("12.00") ],
                                                     [ "200", "web", 3, 80, 0, BigDecimal("4.00") ]
                                                   ])

    expect(fills).to eq([ BigDecimal("50.00"), BigDecimal("20.00"), BigDecimal("29.00") ])
  end

  it "balances both ledgers independently for each date" do
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20.csv"))
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-21.csv"))
    drain!

    expect(BilledStat.where(date: Date.new(2026, 8, 20)).sum(:engagements)).to eq(1100)
    # 700 = 100 (B1) + 500 (B3) + 100 (unbilled bucket).
    expect(BilledStat.where(date: Date.new(2026, 8, 20)).sum(:premium_engagements)).to eq(700)

    expect(BilledStat.where(date: Date.new(2026, 8, 21)).sum(:engagements)).to eq(230)
    expect(BilledStat.where(date: Date.new(2026, 8, 21)).sum(:premium_engagements)).to eq(0)

    expect(Billing::ConservationCheck.call).to be_empty
  end

  it "is idempotent: re-running the biller over billed batches changes nothing" do
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20.csv"))
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-21.csv"))
    drain!

    before = [
      BilledStat.order(:date, :merchant_id, :channel, :budget_id)
                .pluck(:budget_id, :engagements, :premium_engagements, :amount),
      fills
    ]

    drain! # every batch is billed and its digest unchanged — must be a no-op

    expect([
             BilledStat.order(:date, :merchant_id, :channel, :budget_id)
                       .pluck(:budget_id, :engagements, :premium_engagements, :amount),
             fills
           ]).to eq(before)
  end

  it "is idempotent: re-ingesting an identical file does not re-open a billed batch" do
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20.csv"))
    drain!
    expect(BillingBatch.pluck(:state).uniq).to eq([ "billed" ])

    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20.csv")) # byte-identical

    # The digest is unchanged, so nothing became eligible again.
    expect(Billing::ClaimBatch.call(worker_id: "peer")).to be_nil
  end

  it "references only real budgets or the unbilled sentinel" do
    # Buys back the referential integrity given up by not putting a FK on
    # billed_stats.budget_id.
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20.csv"))
    drain!

    ids = BilledStat.distinct.pluck(:budget_id) - [ Billing::Allocator::UNBILLED_BUDGET_ID ]
    expect(ids).not_to be_empty
    expect(Budget.where(id: ids).count).to eq(ids.size)
  end
end
