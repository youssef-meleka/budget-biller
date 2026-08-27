# frozen_string_literal: true

require "rails_helper"

RSpec.describe "billing under concurrency", type: :model do
  THREADS = 4

  self.use_transactional_tests = false

  before do
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean

    expect(ActiveRecord::Base.connection_pool.size).to be >= THREADS + 1
    
    Billing::BillBatch.race_hook = -> { sleep 0.01 }
  end

  after do
    Billing::BillBatch.race_hook = nil
    DatabaseCleaner.clean
  end

  it "conserves both ledgers and never overfills a budget", :skip_conservation do
    primary  = Budget.create!(merchant_id: "m1", cost_model: "CPC", rate: 1, quota: 25, fill: 0)
    fallback = Budget.create!(merchant_id: "m1", cost_model: "CPC", rate: 1, quota: 10, fill: 0)
    primary.update!(fallback_budget_id: fallback.id)

    # 8 batches × 10 engagements = 80 engagements against 35 units of capacity.
    dates = (1..8).map { |d| Date.new(2026, 8, d) }
    dates.each do |date|
      PendingEngagement.create!(date:, merchant_id: "m1", channel: "web", engagements: 10,
                                 premium_engagements: 4, source_file: "t.csv", ingested_at: Time.current)
      BillingBatch.create!(date:, merchant_id: "m1", state: "pending", staging_digest: "seed-#{date}")
    end

    start = Queue.new
    workers = Array.new(THREADS) do |i|
      Thread.new do
        start.pop
        ActiveRecord::Base.connection_pool.with_connection do
          loop { break if Billing::BillBatch.call_next(worker_id: "w#{i}") == :no_work }
        end
      end
    end

    THREADS.times { start << :go }
    workers.each(&:join)

    dates.each do |date|
      # I1 — the engagements ledger balances, per date
      expect(BilledStat.where(date:).sum(:engagements)).to eq(10)
      # I2 — the premium ledger balances INDEPENDENTLY of I1
      expect(BilledStat.where(date:).sum(:premium_engagements)).to eq(4)
    end

    expect(BilledStat.sum(:engagements)).to eq(80)
    expect(BilledStat.sum(:premium_engagements)).to eq(32)

    # I3 — no budget over quota, under real contention
    Budget.find_each { |b| expect(b.fill).to be <= b.quota }

    # Capacity was actually exhausted — without this the test never reached
    # the contended state and would pass against a broken design.
    expect(primary.reload.fill).to eq(25)
    expect(fallback.reload.fill).to eq(10)

    # No batch lost to a claim race, and no batch billed twice.
    expect(BillingBatch.where.not(state: "billed").count).to eq(0)
    expect(BilledStat.group(:date, :merchant_id, :channel, :budget_id).count.values.max).to eq(1)

    expect(Billing::ConservationCheck.call).to be_empty
  end

  it "reclaims a batch whose lease expired, so a dead worker never blocks it forever" do
    # Simulates a crashed worker without actually killing a process.
    budget = Budget.create!(merchant_id: "m2", cost_model: "CPC", rate: 1, quota: 100, fill: 0)
    date = Date.new(2026, 9, 1)
    PendingEngagement.create!(date:, merchant_id: "m2", channel: "web", engagements: 10,
                               premium_engagements: 0, source_file: "t.csv", ingested_at: Time.current)
    BillingBatch.create!(date:, merchant_id: "m2", state: "pending", staging_digest: "d1")

    claimed = Billing::ClaimBatch.call(worker_id: "dead-worker")
    expect(claimed).not_to be_nil
    expect(Billing::ClaimBatch.call(worker_id: "peer")).to be_nil # held by a live lease

    claimed.update!(lease_expires_at: 1.minute.ago) # the worker "died"

    expect(Billing::BillBatch.call_next(worker_id: "peer")).to eq(:billed)
    expect(BillingBatch.find(claimed.id).state).to eq("billed")
    expect(budget.reload.fill).to eq(10)
  end

  it "fences out a stale lease-holder: it raises LeaseLost and commits nothing" do
    budget = Budget.create!(merchant_id: "m3", cost_model: "CPC", rate: 1, quota: 100, fill: 0)
    date = Date.new(2026, 9, 2)
    PendingEngagement.create!(date:, merchant_id: "m3", channel: "web", engagements: 10,
                               premium_engagements: 0, source_file: "t.csv", ingested_at: Time.current)
    batch = BillingBatch.create!(date:, merchant_id: "m3", state: "pending", staging_digest: "d1")

    # A worker claims, then stalls long enough for its lease to lapse.
    stale = Billing::ClaimBatch.call(worker_id: "paused-worker")
    stale.update!(lease_expires_at: 1.minute.ago)

    expect { Billing::BillBatch.send(:bill!, stale, worker_id: "paused-worker") }
      .to raise_error(Billing::LeaseLost)

    # Nothing it did survived: no rows, no fill movement, batch still open.
    expect(BilledStat.where(date:).count).to eq(0)
    expect(budget.reload.fill).to eq(0)
    expect(batch.reload.state).to eq("claimed")
  end
end
