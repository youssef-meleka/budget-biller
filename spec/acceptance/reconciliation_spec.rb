# frozen_string_literal: true

require "rails_helper"

RSpec.describe "reconciliation from a corrected file", type: :model do
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
    loop { break if Billing::BillBatch.call_next(worker_id: "reconciler") == :no_work }
  end

  before do
    seed_budgets!
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20.csv"))
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-21.csv"))
    drain!
  end

  it "re-opens only the affected batches when the corrected file changes the staged data" do
    expect(BillingBatch.pluck(:state).uniq).to eq([ "billed" ])

    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20_v2.csv"))

    # Merchant 100 on 2026-08-20 changed (400 -> 350), so its digest moved and
    # the batch is eligible again. Merchant 200's rows are byte-identical, so
    # its digest is unchanged and stays ineligible.
    changed = BillingBatch.find_by(date: Date.new(2026, 8, 20), merchant_id: "100")
    unchanged = BillingBatch.find_by(date: Date.new(2026, 8, 20), merchant_id: "200")

    expect(changed.staging_digest).not_to eq(changed.billed_digest)
    expect(unchanged.staging_digest).to eq(unchanged.billed_digest)

    claimed = Billing::ClaimBatch.call(worker_id: "peer")
    expect(claimed.id).to eq(changed.id)
    expect(Billing::ClaimBatch.call(worker_id: "peer2")).to be_nil # only the one batch re-opened
  end

  it "reverses the old rows and re-bills, landing on the documented final fills" do
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20_v2.csv"))
    drain!

    expect(Budget.order(:id).pluck(:fill)).to eq([
                                                    BigDecimal("50.00"), BigDecimal("16.00"), BigDecimal("29.00")
                                                  ])
  end

  it "leaves no 2026-08-20 rows from the first run in billed_stats" do
    first_run_ids = BilledStat.where(date: Date.new(2026, 8, 20), merchant_id: "100")
                              .distinct.pluck(:billing_run_id)
    expect(first_run_ids).not_to be_empty

    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20_v2.csv"))
    drain!

    remaining = BilledStat.where(date: Date.new(2026, 8, 20), merchant_id: "100")
                          .distinct.pluck(:billing_run_id)
    expect(remaining & first_run_ids).to be_empty

    # Row 2 spills its remainder to B2 once B1 fills exactly at 50.00.
    expect(BilledStat.where(date: Date.new(2026, 8, 20), merchant_id: "100")
                     .order(:channel, :budget_id)
                     .pluck(:channel, :budget_id, :engagements, :amount)).to eq([
                                                                                   [ "app", 1, 350, BigDecimal("35.00") ],
                                                                                   [ "web", 1, 150, BigDecimal("15.00") ],
                                                                                   [ "web", 2, 50, BigDecimal("4.00") ]
                                                                                 ])
  end

  it "keeps both ledgers balanced after reconciliation, not only after the first pass" do
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20_v2.csv"))
    drain!

    expect(BilledStat.where(date: Date.new(2026, 8, 20)).sum(:engagements)).to eq(1050)
    expect(BilledStat.where(date: Date.new(2026, 8, 20)).sum(:premium_engagements)).to eq(700)
    expect(Billing::ConservationCheck.call).to be_empty
  end

  it "settles: a second run after reconciliation changes nothing further" do
    Ingest::LoadFile.call(Rails.root.join("data/stats_2026-08-20_v2.csv"))
    drain!

    before = [ BilledStat.order(:id).pluck(:date, :merchant_id, :channel, :budget_id, :engagements, :amount),
              Budget.order(:id).pluck(:fill) ]

    drain!

    expect([ BilledStat.order(:id).pluck(:date, :merchant_id, :channel, :budget_id, :engagements, :amount),
            Budget.order(:id).pluck(:fill) ]).to eq(before)
  end
end
