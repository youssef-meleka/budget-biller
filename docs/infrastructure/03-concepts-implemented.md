# Concepts Implemented — With Code

Every distributed-systems/concurrency concept in this codebase, what it solves, and where to find
it. File paths point at the dedicated file — open it directly to see the concept in full context;
line numbers are omitted deliberately since they drift as the code changes, but the shape below is
stable.

## 1. Idempotency — two mechanisms, one pattern

**Ingest idempotency** (loading the same CSV twice must produce the same result as loading it once):
upsert on the *business key*, not `(file, line number)`.

File: `app/services/ingest/load_file.rb`
```ruby
PendingEngagement.upsert_all(
  records,
  unique_by: %i[date merchant_id channel],
  update_only: %i[engagements premium_engagements source_file ingested_at]
)
```

**Billing idempotency** (a batch that's already billed must stay billed): a unique index is the
actual enforcement — `RecordNotUnique` becomes expected control flow, not an exception to swallow.

File: `db/migrate/20260101000004_create_billed_stats.rb`
```ruby
add_index :billed_stats, %i[date merchant_id channel budget_id], unique: true
```

File: `app/services/billing/bill_batch.rb`
```ruby
rescue ActiveRecord::RecordNotUnique
  # a peer already billed this exact batch and our insert collided with it
  Rails.logger.info(log_line("batch.already_billed", batch, worker_id:))
  batch.update!(state: "billed")
  :already_billed
```

## 2. Atomic claim (no check-then-set)

One round-trip `UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED) RETURNING *`. The read
(what's eligible) and the write (claim it) can't interleave — and `SKIP LOCKED` is what lets N
workers grab N *different* rows instead of queueing behind one.

File: `app/services/billing/claim_batch.rb`
```sql
UPDATE billing_batches
   SET state = 'claimed', claimed_by = ?, claimed_at = NOW(),
       lease_expires_at = NOW() + (? || ' seconds')::interval,
       attempts = attempts + 1
 WHERE id = (
   SELECT id FROM billing_batches
    WHERE state != 'failed'
      AND (state = 'pending'
        OR (state = 'claimed' AND lease_expires_at < NOW())
        OR (state = 'billed'  AND staging_digest != billed_digest))
    ORDER BY date ASC, merchant_id ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
 )
RETURNING *
```

## 3. Pessimistic locking, with ordering to avoid deadlocks

Budgets are locked `FOR UPDATE` in ascending `id` order before anything reads capacity from them —
two workers touching the same two budgets always try to lock them in the same order, so they can't
deadlock against each other.

File: `app/services/billing/bill_batch.rb`
```ruby
budgets = Budget.where(merchant_id: batch.merchant_id).order(:id).lock.to_a # ascending id
```

## 4. Guarded conditional update (atomic fill, never read-modify-write)

The arithmetic *and* the quota check happen in one database statement — never
`budget.fill += x; budget.save!`, which is a classic lost-update bug under concurrency (two workers
both read the same starting value, both compute a new value, and one write clobbers the other).

File: `app/services/billing/bill_batch.rb`
```ruby
def self.charge_budget!(budget_id, amount)
  rows = Budget.where(id: budget_id)
                .where("fill + ? <= quota", amount)
                .update_all([ "fill = fill + ?", amount ])

  raise Billing::CapacityRaced, "budget #{budget_id} capacity raced" if rows.zero?
end
```

## 5. Deadlock retry with jitter

Ordering makes deadlocks *rare*, not impossible — the database can still kill a transaction to break
a cycle. Bounded retries with randomized backoff stop retriers from re-colliding in lockstep.

File: `app/services/billing/bill_batch.rb`
```ruby
def self.bill!(batch, worker_id:)
  attempts = 0
  begin
    bill_once!(batch, worker_id:)
  rescue ActiveRecord::Deadlocked
    attempts += 1
    raise if attempts > MAX_DEADLOCK_RETRIES
    sleep(0.05 * attempts * (1 + rand)) # jittered
    retry
  end
end
```

## 6. Lease-based crash recovery

A worker that dies mid-batch doesn't block that batch forever — the lease simply expires, and the
claim query's own predicate (`state = 'claimed' AND lease_expires_at < NOW()`) makes the batch
claimable again. No separate reaper process needed.

File: `db/migrate/20260101000003_create_billing_batches.rb`
```ruby
t.datetime :lease_expires_at   # crash recovery
```

File: `config/initializers/billing.rb`
```ruby
LEASE_TTL = ENV.fetch("BILLING_LEASE_TTL", 60).to_i
```

## 7. Fencing token (rejecting a zombie writer)

A worker that merely *paused* (GC, a frozen VM, a slow disk) rather than crashed can wake up after
its lease has already expired and a peer has taken over. The final commit re-asserts ownership and
an unexpired lease — if that update doesn't touch exactly one row, the whole transaction rolls back
instead of silently overwriting the peer's work.

File: `app/services/billing/bill_batch.rb`
```ruby
def self.fence_commit!(batch:, worker_id:, billing_run_id:)
  fenced = BillingBatch.where(id: batch.id, claimed_by: worker_id, state: "claimed")
                        .where("lease_expires_at > NOW()")
                        .update_all(updates)

  raise Billing::LeaseLost, "lease lost for batch #{batch.id}" if fenced != 1
end
```

## 8. Poison-pill bound

A batch that keeps failing (bad data, a bug) doesn't retry forever and doesn't get silently dropped —
it goes terminally `failed` after `MAX_ATTEMPTS`, which shows up loudly as an imbalance rather than
vanishing quietly.

File: `app/services/billing/bill_batch.rb`
```ruby
rescue Billing::Error, ActiveRecord::StatementInvalid => e
  Rails.logger.error(log_line("batch.failed", batch, worker_id:, error: e.message, class: e.class.name))
  batch.update!(state: "failed") if batch.attempts >= Billing::MAX_ATTEMPTS
  :failed
```

## 9. Database as the single clock

Every lease timestamp comes from the database's own `NOW()`, never Ruby's `Time.current` — separate
processes' clocks drift independently, so trusting an application process's local clock for a lease
would be unsound.

File: `app/services/billing/claim_batch.rb`
```sql
lease_expires_at = NOW() + (? || ' seconds')::interval
```

## 10. Compensating transaction (reconciliation, not append-only)

A corrected CSV can't "un-commit" an earlier billing run, so the fix is a deliberate inverse —
reverse the stale rows and refund the budget's `fill` — run in the **same transaction** as the
re-bill that follows, so no window exists where the budget looks free to a third worker.

File: `app/services/billing/reconcile.rb`
```ruby
def self.call(date:, merchant_id:, billing_run_id:)
  stale = BilledStat.where(date:, merchant_id:).where.not(billing_run_id:)

  stale.group(:budget_id).sum(:amount).each do |budget_id, amount|
    next if budget_id == Billing::Allocator::UNBILLED_BUDGET_ID
    Budget.where(id: budget_id).update_all([ "fill = fill - ?", amount ])
  end

  stale.delete_all
end
```

Called from inside the same transaction, before the re-bill happens. File: `app/services/billing/bill_batch.rb`
```ruby
reversed = Billing::Reconcile.call(date: batch.date, merchant_id: batch.merchant_id, billing_run_id:)
```

## 11. Change detection via content digest

A hash over the staged rows decides eligibility — an unchanged digest keeps an already-billed batch
closed; a changed digest (from a corrected re-ingest) reopens it automatically, with no separate
"reconciliation mode" to branch into.

File: `app/services/ingest/load_file.rb`
```ruby
def staging_digest_for(date, merchant_id)
  canonical = PendingEngagement.where(date:, merchant_id:).order(:channel)
                                .pluck(:channel, :engagements, :premium_engagements)
  Digest::SHA256.hexdigest(canonical.to_json)
end
```

File: `app/models/billing_batch.rb`
```ruby
scope :eligible, lambda {
  where.not(state: "failed")
       .where("state != 'billed' OR staging_digest != billed_digest")
}
```

## 12. Database-enforced invariants (CHECK constraints as a backstop)

Correctness doesn't rely on the Ruby code being bug-free — the schema itself refuses an impossible
state, independent of what wrote it.

File: `db/migrate/20260101000001_create_budgets.rb`
```ruby
add_check_constraint :budgets, "fill <= quota", name: "budgets_fill_within_quota"
add_check_constraint :budgets, "fill >= 0",     name: "budgets_fill_non_negative"
```

## 13. Pure functional core / imperative shell

All allocation math lives in a function with no ActiveRecord, no database, no clock — the same
inputs always produce the same outputs. Every side effect (locking, persistence, transactions) lives
outside it, in the billing service that calls it. This separation is what lets the allocator's test
suite run in milliseconds with zero database involved.

File: `app/services/billing/allocator.rb`
```ruby
# THE FUNCTIONAL CORE. Same inputs -> same outputs. No database, no clock,
# no randomness, no logger, no ActiveRecord objects.
class Allocator
  def call(record:, budgets:, primary_budget_id:)
    # ... pure computation only
```

## 14. Conservation invariants, made executable

The "money can't be created or destroyed" rules aren't just tested once at build time — they're a
standing query that can be run against any live database state, at any point.

File: `app/services/billing/conservation_check.rb`
```ruby
def call
  engagements + premium + overfills
end

def overfills
  Budget.where("fill > quota").map do |b|
    Violation.new(kind: :overfill, key: b.id, expected: b.quota, actual: b.fill)
  end
end
```

## 15. Graceful shutdown

`SIGTERM`/`SIGINT` stop the worker from claiming *new* work but let the in-flight batch finish, so a
deploy or a container stop never leaves a batch stuck claimed until its lease naturally expires.

File: `lib/tasks/billing.rake`
```ruby
Signal.trap("TERM") { shutdown = true }
Signal.trap("INT")  { shutdown = true }

until shutdown
  result = Billing::BillBatch.call_next(worker_id:)
  sleep(Billing::POLL_INTERVAL) if result == :no_work && !shutdown
end
```

---

## Where each concept is proven, not just implemented

| Concept | Spec file |
|---|---|
| Pure allocation logic | `spec/services/billing/allocator_spec.rb` |
| Ingest idempotency | `spec/services/ingest/load_file_spec.rb` |
| Atomic claim, guarded fill, real thread contention | `spec/concurrency/billing_spec.rb` — 4 real threads, shared database, no transactional test fixtures |
| Compensating transaction / reconciliation | `spec/acceptance/reconciliation_spec.rb` |
| End-to-end conservation | `spec/acceptance/worked_examples_spec.rb` |
