# Budget Biller

Batch billing pipeline: CSV engagement data is ingested into a staging table, then N concurrent
workers claim `(date, merchant_id)` batches and allocate them against merchant budgets. All three
tiers are implemented. Ruby 3.3 / Rails 7.2 (no HTTP surface) / PostgreSQL 16, all in Docker.

## Run it

```bash
cp .env.example .env                       # set UID/GID if not 1000:1000
docker compose build
docker compose up -d postgres app
docker compose exec app bin/rails db:create db:migrate db:seed
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-20.csv]"
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-21.csv]"
docker compose up -d --scale worker=3      # workers claim and bill on their own
docker compose exec app bin/rails billing:verify   # the three invariants, executable
docker compose exec -e RAILS_ENV=test app bundle exec rspec
```

`billing:drain` bills until no work remains and exits (used for scripted runs and the specs).
`billed_stats.csv` is the dump of all three provided files, including the correction.

Full container reference — what each service/file does, first-time setup, and the daily-use command
list — is in [docker/README.md](docker/README.md).

## Concurrency mechanism, and why

| Concern | Mechanism |
|---|---|
| Claim a batch | One statement: `UPDATE … WHERE id = (SELECT … FOR UPDATE SKIP LOCKED) RETURNING *`. The read and the write cannot interleave, so there is no check-then-set window. `SKIP LOCKED` is what makes workers *scale* rather than serialise onto one row |
| Charge a budget | `UPDATE budgets SET fill = fill + ? WHERE fill + ? <= quota`, under a row lock. The arithmetic and the quota check happen in the database, in one statement — never `budget.fill += x` |
| Compute capacity | Budgets are locked `FOR UPDATE` in **ascending id order** before capacity is read. Ordering is the deadlock fix: a record spilling into a fallback touches two rows, and locking them in "logical" order cycles |
| Crash recovery | A lease (`lease_expires_at`), reclaimed by the claim predicate itself — no reaper process to keep alive. `attempts` is bounded; at `MAX_ATTEMPTS` the batch goes terminally `failed` and leaves a loud imbalance rather than vanishing |
| A *paused* worker | A **fencing token**: the final transition asserts `claimed_by = me AND lease_expires_at > NOW()` and raises `LeaseLost` if it did not update exactly one row. It rejects the zombie before it commits, where the unique index would only absorb it afterwards |
| Clock skew | Every lease timestamp comes from the database `NOW()`, never `Time.current` — replica clocks drift independently and nothing synchronises them |

**Optimistic vs pessimistic, deliberately split.** The claim is pessimistic (`SKIP LOCKED`): claims are
highly contended and cheap to skip. The charge is a guarded conditional update *under a held row lock*,
because allocation must compute *how many engagements fit*, which needs a stable read of `quota - fill`.
The honest cost: two workers billing different batches of the same merchant serialise on that
merchant's budget rows. At this batch size the lock is held for milliseconds.

**Isolation: `READ COMMITTED`** (Postgres' default). Correctness rests on row locks and conditional
updates rather than on the isolation level, which is the more robust choice — it does not depend on
the reader configuring anything. `SERIALIZABLE` was considered; it converts anomalies into aborts and
would need a retry loop, buying nothing the local guard does not already give.

**Postgres, not SQLite** (the brief allows either). SQLite has no row-level locking, no
`FOR UPDATE SKIP LOCKED`, no advisory locks, and one writer database-wide. A "concurrent workers" test
on SQLite passes trivially because the database serialises everything — proving nothing about the
design and demonstrating none of the mechanisms Tier 2 grades.

## Idempotency

Both idempotency rules are **one** mechanism, not two. Ingest upserts on the natural key
`(date, merchant_id, channel)` — business identity, *not* `(source_file, line_no)` — so a corrected
file **overwrites** rather than appends, then recomputes a `staging_digest` over the batch's staged
rows. A batch is eligible iff `state != 'failed' AND (state != 'billed' OR staging_digest != billed_digest)`.
Re-ingesting an identical file leaves the digest unchanged, so the batch stays ineligible (rule 4);
re-ingesting `_v2` changes it, so the batch re-opens by itself (rule 10) — no reconciliation mode
anywhere. On commit, `billed_digest = staging_digest` closes the loop.

Every guarantee is a constraint, not an `if`: unique indexes on `pending_engagements (date, merchant, channel)`,
`billing_batches (date, merchant)`, and `billed_stats (date, merchant, channel, budget)`, plus
`CHECK (fill <= quota)` and `CHECK (fill >= 0)`. `RecordNotUnique` is handled as expected control flow.
The eligibility predicate is the fast path; the unique index is the correctness boundary.

## Decisions worth naming

- **Rounding is `floor`, in exactly one place** — `(capacity / rate).floor`. `round` can return a count
  whose charge exceeds remaining capacity by a fraction of a cent, violating rule 1 and tripping
  `CHECK (fill <= quota)` intermittently. Money is `decimal`/`BigDecimal` throughout, and every CSV
  number is parsed with `Integer(...)`/`BigDecimal(...)` — never `to_f`, which would let a Float in at
  the boundary that `decimal` columns cannot save you from.
- **`budget_id = 0` with no FK on `billed_stats`.** The brief mandates the literal sentinel and
  `budgets.id` starts at 1, so a FK would reject every bucket row. The alternative — seeding a real
  `id = 0` budget — restores the FK but collides with `CHECK (rate > 0)` and adds a row every aggregate
  over `budgets` must exclude. The lost referential integrity is bought back with a spec asserting
  every `budget_id` is either real or the sentinel.
- **Premium split across a fallback spill is `fill-first`, and the input data does not settle it.**
  The only splitting row carries zero premium and the only row with premium overage does not split, so
  both fill-first and proportional conserve I2 and **no invariant or worked example can catch a wrong
  choice**. It is isolated behind `Allocator#premium_for` and spec'd on *both* budgets' premium counts,
  not just their sum. Proportional would need a rounding policy of its own and still have to assign the
  remainder deterministically.
- **`cost_model (CPC|UEV)` is descriptive metadata; nothing branches on it.** Evidence: B3 is `UEV`
  with 500 engagements and 600 premium, and the worked charge is `500 × 0.05 = 25.00`. If `UEV` billed
  premium it would be 30.00 — which is *exactly* B3's quota, so a wrong implementation would look
  plausible.
- **Record order within a batch is `ORDER BY channel`** — explicit, stable, needs no extra column.
  Order matters because a budget filling mid-merchant decides which channel takes the spill. The given
  data cannot discriminate between `channel` and a `source_line` column (the only multi-channel batch
  is already alphabetical), so this is a documented choice, not a proven one.
- **Reconciliation is a compensating transaction**: reversal and re-bill share **one** transaction, with
  budgets locked ascending and `fill = fill - ?` applied DB-side. Splitting them would leave a window
  where the budget looks free. Append-only with reversal rows is the standard audit-preserving
  alternative and is **disqualified by the brief's own check** ("No 2026-08-20 rows from the first run
  may remain"); it would also force the unique index to widen and `CHECK (engagements >= 0)` to be
  dropped.
- **Reconciliation does not cascade to later dates.** Re-billing a corrected date cannot invalidate a
  later one *here* only because the correction happens to refill B1 to exactly 50.00, leaving Aug 21's
  allocation still valid. Had it left headroom, Aug 21 would be stale, nothing would re-bill it, and
  **every invariant in this design would still pass** — I1/I2/I3 are all per-date. That is a limitation,
  not a property.

## Tests

`rspec` — 33 examples. Read `spec/services/billing/allocator_spec.rb` first: the allocator is pure
(no ActiveRecord, no DB, no clock, no logger), so every fallback, exhaustion, boundary and conservation
case is a millisecond-level unit test. `spec/concurrency/billing_spec.rb` is the pass bar — 4 real
threads on a shared database, released together by a latch, with `use_transactional_tests = false`,
truncation cleaning, and a pool larger than the thread count. It asserts I1 and I2 per date, I3, that
capacity was **actually exhausted** (`fill == quota` exactly), that every batch is terminal, and that no
`(date, merchant, channel, budget)` repeats. Lease-expiry and fencing each have their own spec, and
`ConservationCheck` runs in an `after` hook of every integration spec.

**The concurrency spec was verified to fail against a naive implementation.** Replacing the guarded
update *and* the row lock with `budget.fill += x; budget.save!` makes it fail: `fill` is driven to 30.00
against a quota of 25.00, caught by `CHECK (fill <= quota)`, and I1 breaks. One nuance worth stating
honestly: with the pessimistic row lock left *in place*, the naive read-modify-write still passes —
the lock alone serialises the charge. The spec detects the loss of the lock (with or without the guard),
which is the mechanism this design actually leans on; the guard and the `CHECK` are the layers beneath it.

## With more time

| Concept | Status |
|---|---|
| At-least-once + idempotent consumer = effectively-once | The spine of the design |
| Fencing token; compensating transaction; poison-pill bound; database as the single clock | Implemented |
| Optimistic/pessimistic split (`SKIP LOCKED` claim, guarded update for the charge) | Implemented |
| Transactional outbox — emitting `batch.billed` to a bus without a dual-write | Considered; not needed, nothing here consumes such an event |
| `SERIALIZABLE` + retry | Considered; rejected, the local guard is cheaper and needs no retry loop |
| Append-only ledger with reversal rows | Considered; ruled out by the brief's "no stale rows" check |
| Cascading recomputation of later dates | Not implemented; named above as a real limitation |
| Heartbeat lease extension | Not needed at this batch size; the answer if batch duration were unbounded |
| Sharding the claim by `hash(merchant_id) % N` | Not needed; the answer if `SKIP LOCKED` contention ever became the bottleneck |
| Integer minor units for money | Considered; `decimal` chosen for readability, knowing it keeps a rounding site |

Also with more time: resolve `primary_budget_id` explicitly rather than by inferring the fallback-forest
root (a budget no other budget of that merchant falls back to), which is unambiguous on this data but
would not be if a merchant had two independent entry budgets.

## Navigate to Docs

- [docs/infrastructure/01-file-map.md](docs/infrastructure/01-file-map.md) — every folder and file, what it does
- [docs/infrastructure/02-technology-choices.md](docs/infrastructure/02-technology-choices.md) — why Postgres, Ruby, Rails, and the rest of the stack were chosen
- [docs/infrastructure/03-concepts-implemented.md](docs/infrastructure/03-concepts-implemented.md) — every concurrency/idempotency/reliability concept, with code snippets and file references
- [docker/README.md](docker/README.md) — what Docker provides here, every file's purpose, first-time setup, and daily-use commands
- [docs/Test Run/README.md](docs/Test%20Run/README.md) — a full end-to-end transcript of a real run: every command in order, real output at each step, and the invariants checked before and after the correction
