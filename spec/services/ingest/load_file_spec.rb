# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ingest::LoadFile, type: :model do
  let(:path) { Rails.root.join("data/stats_2026-08-20.csv") }

  def snapshot
    PendingEngagement.order(:id).pluck(:date, :merchant_id, :channel, :engagements, :premium_engagements)
  end

  it "loads every row from the file into pending_engagements" do
    described_class.call(path)

    expect(PendingEngagement.count).to eq(3)
    expect(snapshot).to contain_exactly(
      [ Date.new(2026, 8, 20), "100", "app", 400, 100 ],
      [ Date.new(2026, 8, 20), "100", "web", 200, 0 ],
      [ Date.new(2026, 8, 20), "200", "app", 500, 600 ]
    )
  end

  it "creates one billing_batch per (date, merchant_id)" do
    described_class.call(path)

    expect(BillingBatch.count).to eq(2)
    expect(BillingBatch.pluck(:merchant_id)).to contain_exactly("100", "200")
    expect(BillingBatch.pluck(:state).uniq).to eq([ "pending" ])
  end

  it "is idempotent: ingesting the same file twice matches ingesting it once" do
    described_class.call(path)
    before_engagements = snapshot
    before_batches = BillingBatch.order(:merchant_id).pluck(:date, :merchant_id, :staging_digest)

    expect { described_class.call(path) }.not_to change(PendingEngagement, :count)
    expect(snapshot).to eq(before_engagements)
    expect(BillingBatch.order(:merchant_id).pluck(:date, :merchant_id, :staging_digest)).to eq(before_batches)
    expect(BillingBatch.count).to eq(before_batches.size)
  end

  it "overwrites (not appends) when a corrected file changes an existing (date, merchant, channel) row" do
    described_class.call(path)
    original_digest = BillingBatch.find_by(merchant_id: "100").staging_digest

    described_class.call(Rails.root.join("data/stats_2026-08-20_v2.csv"))

    expect(PendingEngagement.count).to eq(3) # still 3 rows, not 6 — corrected, not appended
    row = PendingEngagement.find_by(date: Date.new(2026, 8, 20), merchant_id: "100", channel: "app")
    expect(row.engagements).to eq(350)

    expect(BillingBatch.find_by(merchant_id: "100").staging_digest).not_to eq(original_digest)
  end
end
