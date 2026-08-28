# Test Run — the whole pipeline, one command at a time

This is a **transcript of a real run**, not a plan. Every command below was executed against a
clean Docker environment on 2026-08-28, and every block labelled *output* is copied verbatim from
that session. Timings, container names, worker ids and UUIDs are the real ones.

- Wall-clock start: `16:56:52Z` (`docker compose up`)
- Wall-clock end: `16:59:49Z` (workers stopped)
- **Total: 2 minutes 57 seconds**, including image build wait, two ingests, three worker replicas,
  a mid-flight correction, a full reconciliation, and the 33-example test suite.

Companion files in this folder:

| File | What it is |
|---|---|
| [billed_stats.csv](billed_stats.csv) | The final `billed_stats` dump — the deliverable the brief asks for |
| [run-timeline.md](run-timeline.md) | Every in-process log line with UTC timestamps and elapsed offsets |

---

## Phase 0 — Prerequisites and build

```bash
cp .env.example .env       # edit UID/GID inside if your host isn't 1000:1000
docker compose build
```

`.env` is the single source of configuration. The values that shape this run:

```
BILLING_POLL_INTERVAL=5    # a worker with no work sleeps 5s before asking again
BILLING_LEASE_TTL=60       # a claim is held for 60s; after that any peer may steal it
BILLING_MAX_ATTEMPTS=5     # poison-batch bound
RAILS_MAX_THREADS=10       # connection pool — must exceed the concurrency spec's 4 threads
```

The build produces **one image** (`budget_biller/app`) that both `app` and `worker` run — same code,
different command. It takes ~90s cold, of which ~44s is `bundle install` into a cached layer.

```
#10 43.38 Bundle complete! 6 Gemfile dependencies, 92 gems now installed.
#13 naming to docker.io/budget_biller/app:latest done
 budget_biller/app  Built
```

> If you are re-running, start from a genuinely clean slate with `docker compose down -v`. The `-v`
> destroys the `pgdata` volume — without it you inherit the previous run's fills and the numbers
> below will not reproduce.

---

## Phase 1 — Bring up the datastore and the shell

```bash
docker compose up -d postgres app
```

Two services only. `postgres` is the real dependency; `app` is an idle `sleep infinity` container
that exists purely as a stable place to `exec` rake tasks into. **No workers yet** — that is
deliberate, so you can watch the staging table fill up before anything claims it.

*Output — note `Container budget_biller-postgres-1  Healthy` before `app` is allowed to start:*

```
 Container budget_biller-postgres-1  Started
 Container budget_biller-postgres-1  Waiting
 Container budget_biller-postgres-1  Healthy
 Container budget_biller-app-1  Started
```

That `Waiting → Healthy` pair is `depends_on: condition: service_healthy` doing its job: the app
container physically cannot race Postgres' own startup. Confirm:

```bash
docker compose ps
```

```
NAME                       IMAGE                COMMAND             SERVICE    STATUS
budget_biller-app-1        budget_biller/app    "sleep infinity"    app        Up
budget_biller-postgres-1   postgres:16-alpine   "docker-entrypo…"   postgres   Up (healthy)
```

**Elapsed: 8s.**

---

## Phase 2 — Schema and seed budgets

```bash
docker compose exec app bin/rails db:create db:migrate db:seed
```

Three things happen, and it is worth separating them:

1. `db:create` — reports `Database 'budget_biller_development' already exists`. That is **not an
   error**: the `postgres` container already created it from `POSTGRES_DB` in `.env`. The task is
   here so the sequence also works against an external database.
2. `db:migrate` — four migrations. Watch what they add beyond tables:

```
== 20260101000001 CreateBudgets: migrating ====================================
-- add_check_constraint(:budgets, "fill <= quota", {:name=>"budgets_fill_within_quota"})
-- add_check_constraint(:budgets, "fill >= 0", {:name=>"budgets_fill_non_negative"})
== 20260101000002 CreatePendingEngagements: migrating =========================
-- add_index(:pending_engagements, [:date, :merchant_id, :channel], {:unique=>true})
== 20260101000003 CreateBillingBatches: migrating =============================
-- add_index(:billing_batches, [:date, :merchant_id], {:unique=>true})
== 20260101000004 CreateBilledStats: migrating ================================
-- add_index(:billed_stats, [:date, :merchant_id, :channel, :budget_id], {:unique=>true})
```

   Those four lines *are* the correctness boundary. `CHECK (fill <= quota)` means invariant I3 is
   enforced by Postgres, not by application code — a bug cannot write an overfill even if it tries.
   The three unique indexes make double-ingest and double-bill physically impossible rather than
   merely unlikely.

3. `db:seed` — loads `data/budgets.csv`. **This is setup data, not ingest.** It runs once, before
   the first billing run, and it is idempotent (`find_or_initialize_by` + a second pass for the
   `fallback_budget_id` forward reference, then `reset_pk_sequence!`).

Verify the starting position — every worked example in the brief assumes exactly this:

```bash
docker compose exec postgres psql -U app -d budget_biller_development \
  -c "SELECT id, merchant_id, cost_model, rate, quota, fill, fallback_budget_id FROM budgets ORDER BY id;"
```

```
 id | merchant_id | cost_model |  rate  | quota | fill | fallback_budget_id
----+-------------+------------+--------+-------+------+--------------------
  1 | 100         | CPC        | 0.1000 | 50.00 | 0.00 |                  2
  2 | 100         | CPC        | 0.0800 | 20.00 | 0.00 |
  3 | 200         | UEV        | 0.0500 | 30.00 | 0.00 |
(3 rows)
```

B1 → falls back to → B2. B3 stands alone. All fills at `0.00`. **Elapsed: 1.6s.**

---

## Phase 3 — Ingest (step 1 of the two-step architecture)

Ingest is pure I/O: parse a CSV, upsert it into staging, recompute a digest per
`(date, merchant_id)` batch. **It bills nothing.** It does not even know what a rate is.

```bash
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-20.csv]"
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-21.csv]"
```

```
{"event":"ingest.completed","file":"data/stats_2026-08-20.csv","rows":3,"batches":2}
ingested 3 rows from data/stats_2026-08-20.csv, touched 2 batch(es)
{"event":"ingest.completed","file":"data/stats_2026-08-21.csv","rows":2,"batches":2}
ingested 2 rows from data/stats_2026-08-21.csv, touched 2 batch(es)
```

Three rows, two batches — because file 1 carries merchant 100 twice (`app`, `web`) and merchant 200
once. Batching is by `(date, merchant_id)`, which is what makes a *budget* the unit of contention.

```bash
docker compose exec postgres psql -U app -d budget_biller_development \
  -c "SELECT date, merchant_id, channel, engagements, premium_engagements, source_file FROM pending_engagements ORDER BY date, merchant_id, channel;" \
  -c "SELECT date, merchant_id, state, left(staging_digest,12) AS staging_digest, billed_digest, attempts FROM billing_batches ORDER BY date, merchant_id;"
```

```
    date    | merchant_id | channel | engagements | premium_engagements |     source_file
------------+-------------+---------+-------------+---------------------+----------------------
 2026-08-20 | 100         | app     |         400 |                 100 | stats_2026-08-20.csv
 2026-08-20 | 100         | web     |         200 |                   0 | stats_2026-08-20.csv
 2026-08-20 | 200         | app     |         500 |                 600 | stats_2026-08-20.csv
 2026-08-21 | 100         | app     |         150 |                   0 | stats_2026-08-21.csv
 2026-08-21 | 200         | web     |          80 |                   0 | stats_2026-08-21.csv
(5 rows)

    date    | merchant_id |  state  | staging_digest | billed_digest | attempts
------------+-------------+---------+----------------+---------------+----------
 2026-08-20 | 100         | pending | 7e89b95ac516   |               |        0
 2026-08-20 | 200         | pending | e4f9137a1a69   |               |        0
 2026-08-21 | 100         | pending | 43a4e1d77ae2   |               |        0
 2026-08-21 | 200         | pending | 76fce4793354   |               |        0
(4 rows)
```

Four batches, all `pending`, each with a `staging_digest` (SHA-256 over the batch's staged rows) and
an empty `billed_digest`. **`staging_digest != billed_digest` is the entire eligibility rule.**
Remember those first-column digests — `7e89b9…` for `(2026-08-20, 100)` is about to change.

**Elapsed: 2.5s for both files.**

---

## Phase 4 — Ingest idempotency (Rule 3), proven before billing starts

Load the *same* file a second time. Loading a CSV twice must leave the staging table exactly as
loading it once did.

```bash
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-20.csv]"
docker compose exec postgres psql -U app -d budget_biller_development \
  -c "SELECT count(*) AS pending_rows FROM pending_engagements;" \
  -c "SELECT date, merchant_id, state, left(staging_digest,12) AS staging_digest FROM billing_batches ORDER BY date, merchant_id;"
```

```
 pending_rows
--------------
            5          <- still 5, not 8

    date    | merchant_id |  state  | staging_digest
------------+-------------+---------+----------------
 2026-08-20 | 100         | pending | 7e89b95ac516   <- byte-identical to Phase 3
 2026-08-20 | 200         | pending | e4f9137a1a69
 2026-08-21 | 100         | pending | 43a4e1d77ae2
 2026-08-21 | 200         | pending | 76fce4793354
```

Five rows, not eight. The digests did not move. The mechanism is `upsert_all(unique_by: [date,
merchant_id, channel])` — one statement, `ON CONFLICT DO UPDATE`, resolved by the database. A
`find_or_create_by` here would be a check-then-set race; the unique index would catch it, but only
after the fact.

Because the digest is unchanged, these batches will not become re-eligible later either — which is
the same mechanism that Rule 4 (billing idempotency) rests on. **One mechanism, two rules.**

---

## Phase 5 — Start the workers (step 2), and let them find the work themselves

```bash
docker compose up -d --scale worker=3
```

There is **no manual billing trigger**. The worker loop is `claim → allocate → persist → repeat`,
sleeping `BILLING_POLL_INTERVAL` when it finds nothing. Scaling to 3 replicas is what makes Tier 2
observable: three independent processes, three independent connections, one shared queue.

```
 Container budget_biller-worker-3  Started
 Container budget_biller-worker-1  Started
 Container budget_biller-worker-2  Started
```

```bash
docker compose logs -f worker
```

*Real output, reordered into strict chronological order (the four batches were drained in **660
milliseconds**):*

```
16:57:33.627  worker-3  {"event":"worker.started","worker_id":"ac54b6018d11-1"}
16:57:33.817  worker-1  {"event":"worker.started","worker_id":"c2692c803e9f-1"}
16:57:33.994  worker-3  {"event":"batch.claimed","date":"2026-08-20","merchant_id":"100","attempts":1,"lease_expires_at":"16:58:33.949Z"}
16:57:34.003  worker-2  {"event":"worker.started","worker_id":"8f075844ff33-1"}
16:57:34.133  worker-3  {"event":"batch.billed","date":"2026-08-20","merchant_id":"100","allocations":3,"amount":"58.0","reversed_rows":0}
16:57:34.144  worker-3  {"event":"batch.claimed","date":"2026-08-21","merchant_id":"100","attempts":1,"lease_expires_at":"16:58:34.139Z"}
16:57:34.156  worker-1  {"event":"batch.claimed","date":"2026-08-20","merchant_id":"200","attempts":1,"lease_expires_at":"16:58:34.114Z"}
16:57:34.162  worker-3  {"event":"batch.billed","date":"2026-08-21","merchant_id":"100","allocations":1,"amount":"12.0"}
16:57:34.169  worker-3  {"event":"batch.claimed","date":"2026-08-21","merchant_id":"200","attempts":1,"lease_expires_at":"16:58:34.166Z"}
16:57:34.196  worker-3  {"event":"batch.billed","date":"2026-08-21","merchant_id":"200","allocations":1,"amount":"4.0"}
16:57:34.293  worker-1  {"event":"batch.billed","date":"2026-08-20","merchant_id":"200","allocations":2,"amount":"25.0"}
```

**Read the 12 milliseconds between `16:57:34.144` and `16:57:34.156`.** worker-3 holds
`(2026-08-20, 100)`'s successor while worker-1 claims `(2026-08-20, 200)` — two different workers,
overlapping claims, *disjoint batches*. That is `FOR UPDATE SKIP LOCKED`: worker-1 did not block
waiting behind worker-3's locked row, it **skipped** it and took the next eligible one. A
check-then-set boolean would have produced either a collision or a queue here.

worker-2 started, found every batch either claimed or gone, logged nothing, and went to sleep. That
is the correct behaviour for an idle replica — and the honest shape of a 4-batch workload across 3
replicas.

Every claim carries a `lease_expires_at` exactly 60s ahead, and **it is computed from the database's
`NOW()`, never `Time.current`.** Three replicas have three independently drifting clocks; only the
database has one.

### What the allocator actually did — traced against the real numbers

**Batch `(2026-08-20, 100)` → `amount: 58.0`, `allocations: 3`.** Records are processed
`ORDER BY channel`, so `app` before `web`:

| Record | Allocation | Arithmetic | Budget after |
|---|---|---|---|
| `app, 400 eng, 100 premium` | B1 gets 400 | `400 × 0.10 = 40.00` | B1 fill `0.00 → 40.00` |
| `web, 200 eng, 0 premium` | B1 gets 100 | capacity `50.00 − 40.00 = 10.00`; `(10.00 / 0.10).floor = 100` | B1 fill `40.00 → 50.00` — **exactly full** |
| ↳ remainder | B2 gets 100 | fallback at *its own* rate: `100 × 0.08 = 8.00` | B2 fill `0.00 → 8.00` |

Total `40 + 10 + 8 = 58.00`. ✅ The `.floor` matters: `round` would have returned 100 engagements
whose charge exceeded remaining capacity by a fraction of a cent and tripped `CHECK (fill <= quota)`
intermittently — a bug that only shows up under load.

**Batch `(2026-08-20, 200)` → `amount: 25.0`, `allocations: 2` for one input row.** `500 × 0.05 =
25.00` to B3, and then the Tier 3 premium overage: the record carries **600** premium engagements
but only **500** were billed to a real budget, so the extra 100 go to a sentinel row
`(budget_id = 0, engagements = 0, premium_engagements = 100, amount = 0.00)`. `engagements = 0` on
that row is the point — the premium ledger balances without disturbing the engagements ledger.

**Batch `(2026-08-21, 100)` → `amount: 12.0`.** B1 is full from yesterday, so the whole record spills
to B2: `150 × 0.08 = 12.00`, B2 `8.00 → 20.00`, exactly full. Note this is *cross-date* state — the
budget carries over, which is why billing order matters and why the batches are claimed
`ORDER BY date ASC`.

**Batch `(2026-08-21, 200)` → `amount: 4.0`.** `80 × 0.05 = 4.00`, B3 `25.00 → 29.00`.

---

## Phase 6 — Verify the three conservation invariants

```bash
docker compose exec app bin/rails billing:verify
```

```
conservation OK: engagements and premium ledgers balance per date, no budget over quota
```

This is not a comment in a README — it is executable, it is the same `Billing::ConservationCheck`
that runs in an `after` hook of every integration spec, and it exits non-zero on violation. The
underlying numbers:

```bash
docker compose exec postgres psql -U app -d budget_biller_development \
  -c "SELECT date, SUM(engagements) AS input_eng, SUM(premium_engagements) AS input_prem FROM pending_engagements GROUP BY date ORDER BY date;" \
  -c "SELECT date, SUM(engagements) AS billed_eng, SUM(premium_engagements) AS billed_prem FROM billed_stats GROUP BY date ORDER BY date;"
```

```
    date    | input_eng | input_prem        date    | billed_eng | billed_prem
------------+-----------+------------    ------------+------------+-------------
 2026-08-20 |      1100 |        700      2026-08-20 |       1100 |         700
 2026-08-21 |       230 |          0      2026-08-21 |        230 |           0
```

**I1** — engagements in = engagements out, per date. **I2** — premium in = premium out, per date,
checked *independently* rather than derived from I1. **I3**:

```
 id | merchant_id |  rate  | quota | fill  | headroom
----+-------------+--------+-------+-------+----------
  1 | 100         | 0.1000 | 50.00 | 50.00 |     0.00
  2 | 100         | 0.0800 | 20.00 | 20.00 |     0.00
  3 | 200         | 0.0500 | 30.00 | 29.00 |     1.00
```

`fill ≤ quota` everywhere, and B1/B2 are at **exactly** their quota — the interesting case, not the
comfortable one. These match `data/worked-examples.md` ("Fills after file 2: B1 = 50.00, B2 = 20.00,
B3 = 29.00") to the cent.

And the batch ledger:

```
    date    | merchant_id | state  |   staging    |    billed    | attempts |   claimed_by
------------+-------------+--------+--------------+--------------+----------+----------------
 2026-08-20 | 100         | billed | 7e89b95ac516 | 7e89b95ac516 |        1 | ac54b6018d11-1
 2026-08-20 | 200         | billed | e4f9137a1a69 | e4f9137a1a69 |        1 | c2692c803e9f-1
 2026-08-21 | 100         | billed | 43a4e1d77ae2 | 43a4e1d77ae2 |        1 | ac54b6018d11-1
 2026-08-21 | 200         | billed | 76fce4793354 | 76fce4793354 |        1 | ac54b6018d11-1
```

`attempts = 1` on all four: **nothing was claimed twice, nothing was retried.** `billed_digest` now
equals `staging_digest`, which is what closes each batch.

---

## Phase 7 — Billing idempotency (Rule 4): let it idle and prove nothing moves

The workers are still running and still polling every 5 seconds. If billing were not idempotent,
this is where money would be created. Snapshot, wait three poll cycles, snapshot again:

```bash
docker compose exec postgres psql -U app -d budget_biller_development \
  -c "SELECT date, merchant_id, attempts, billed_at, billing_run_id FROM billing_batches ORDER BY date, merchant_id;"
sleep 15
docker compose exec postgres psql -U app -d budget_biller_development \
  -c "SELECT date, merchant_id, attempts, billed_at, billing_run_id FROM billing_batches ORDER BY date, merchant_id;" \
  -c "SELECT count(*) AS billed_stats_rows FROM billed_stats;"
```

*At `16:58:16.988` and again at `16:58:32.179` — byte-identical:*

```
    date    | merchant_id | attempts |         billed_at          |            billing_run_id
------------+-------------+----------+----------------------------+--------------------------------------
 2026-08-20 | 100         |        1 | 2026-08-28 16:57:34.014289 | fd5d56a3-9d09-47ce-8376-278a0ea6f9b4
 2026-08-20 | 200         |        1 | 2026-08-28 16:57:34.178457 | 9725840c-bbd6-4ade-9668-e89257b23f7d
 2026-08-21 | 100         |        1 | 2026-08-28 16:57:34.145401 | 93a12ad5-5b9c-43f7-9718-c6a51a53e44b
 2026-08-21 | 200         |        1 | 2026-08-28 16:57:34.170043 | 3e375cee-5802-4c4e-91ef-8b5c9a375db6

 billed_stats_rows
-------------------
                 7
```

Same `attempts`, same `billed_at` to the microsecond, same `billing_run_id`, same row count. Three
replicas polled roughly nine times between those two snapshots and **claimed nothing**, because the
claim SQL's own `WHERE` clause excludes them: `state = 'billed' AND staging_digest = billed_digest`
is not eligible. Idempotency here is not a guard the worker checks after claiming — the work is
never handed out in the first place.

---

## Phase 8 — Reconciliation (Rule 10): a corrected file arrives mid-flight

`stats_2026-08-20_v2.csv` restates an already-billed date: merchant 100's `app` row drops from
**400 → 350** engagements. Everything else is unchanged. The workers keep running the whole time —
**nothing is restarted, nothing is triggered manually.**

```bash
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-20_v2.csv]"
```

```
{"event":"ingest.completed","file":"data/stats_2026-08-20_v2.csv","rows":3,"batches":2}
```

```
    date    | merchant_id | channel | engagements |       source_file
------------+-------------+---------+-------------+-------------------------
 2026-08-20 | 100         | app     |         350 | stats_2026-08-20_v2.csv   <- overwritten, not appended
 2026-08-20 | 100         | web     |         200 | stats_2026-08-20_v2.csv
 2026-08-20 | 200         | app     |         500 | stats_2026-08-20_v2.csv

    date    | merchant_id | state  |   staging    |    billed
------------+-------------+--------+--------------+--------------
 2026-08-20 | 100         | billed | 9525b83d919f | 7e89b95ac516   <- DIVERGED → eligible again
 2026-08-20 | 200         | billed | e4f9137a1a69 | e4f9137a1a69   <- unchanged → still ineligible
 2026-08-21 | 100         | billed | 43a4e1d77ae2 | 43a4e1d77ae2
 2026-08-21 | 200         | billed | 76fce4793354 | 76fce4793354
```

This is the payoff for keying on business identity `(date, merchant_id, channel)` rather than
`(source_file, line_no)`: staging still has **3 rows for 2026-08-20**, not 6. The corrected file
*replaced* the record; it did not accumulate alongside it.

And notice the precision: `(2026-08-20, 100)`'s digest moved `7e89b9… → 9525b8…`, so it re-opened.
`(2026-08-20, 200)`'s digest did not move, so **it was left alone** — even though it is the same
date. Reconciliation is scoped to the batches whose data actually changed. There is no
"reconciliation mode", no separate command, no flag.

Then, unprompted, on the next poll:

```
16:58:32.367  (correction ingested)
16:58:34.269  worker-3  {"event":"batch.claimed","date":"2026-08-20","merchant_id":"100","attempts":2,...}
16:58:34.315  worker-3  {"event":"batch.billed","date":"2026-08-20","merchant_id":"100","attempts":2,
                         "allocations":3,"amount":"54.0","reversed_rows":3}
```

**Picked up 1.9 seconds after ingest, on the natural poll boundary. 46 milliseconds to reverse and
re-bill.** Two fields tell the whole story:

- `attempts: 2` — the same batch row, claimed a second time. Not a new batch.
- `reversed_rows: 3` — the three `billed_stats` rows from run `fd5d56a3…` were **deleted and their
  fill reversed**, inside the *same transaction* that wrote the new ones. Splitting reversal from
  re-bill would leave a window where the budget looks free and a concurrent worker could overspend
  it.

The compensating transaction, step by step:

| | B1 | B2 |
|---|---|---|
| before | `50.00` | `20.00` |
| reverse run `fd5d56a3…` (`fill = fill − amount`, DB-side) | `−50.00 → 0.00` | `−8.00 → 12.00` |
| re-bill `app, 350` → `350 × 0.10 = 35.00` | `→ 35.00` | |
| re-bill `web, 200`: B1 absorbs `(15.00/0.10).floor = 150` → `15.00` | `→ 50.00` (full) | |
| ↳ remainder 50 eng → B2 at `50 × 0.08 = 4.00` | | `→ 16.00` |

`35 + 15 + 4 = 54.00` — exactly the `amount: "54.0"` in the log.

> **One honest note on scoping.** `data/worked-examples.md` narrates the correction as reversing the
> whole *date* (including B3 `−25.00 → 4.00` before re-adding it). This implementation reverses per
> *batch*, and merchant 200's batch never became eligible because its data is identical. The final
> fills are the same either way — B3 stays at `29.00`, which is where the worked example lands too —
> but the reversal is strictly narrower, and merchant 200's rows keep their original
> `billing_run_id` (`9725840c…`) in the dump below. That is visible in the CSV and is intended.

---

## Phase 9 — Verify again, after the correction

```bash
docker compose exec app bin/rails billing:verify
```

```
conservation OK: engagements and premium ledgers balance per date, no budget over quota
```

```
    date    | input_eng | input_prem        date    | billed_eng | billed_prem
------------+-----------+------------    ------------+------------+-------------
 2026-08-20 |      1050 |        700      2026-08-20 |       1050 |         700
 2026-08-21 |       230 |          0      2026-08-21 |        230 |           0
```

The 2026-08-20 engagements total moved `1100 → 1050` on **both sides simultaneously** — the input
changed by −50 and the output followed it exactly. The premium ledger stayed at `700` on both sides,
untouched, because the correction did not touch premium. Two ledgers, balancing independently.

Final budget state:

```
 id | merchant_id |  rate  | quota | fill
----+-------------+--------+-------+-------
  1 | 100         | 0.1000 | 50.00 | 50.00
  2 | 100         | 0.0800 | 20.00 | 16.00   <- was 20.00; the reversal gave 4.00 back
  3 | 200         | 0.0500 | 30.00 | 29.00
```

`B1 = 50.00, B2 = 16.00, B3 = 29.00` — **exactly** `data/worked-examples.md`'s "Final fills".

And the brief's hardest check on this file — *"No 2026-08-20 rows from the first run may remain in
`billed_stats`"*:

```
    date    | merchant_id | channel | budget_id | engagements | ... |            billing_run_id
------------+-------------+---------+-----------+-------------+-----+--------------------------------------
 2026-08-20 | 100         | app     |         1 |         350 | ... | 3904ef7a-551a-41f6-91e1-0374b910a3df
 2026-08-20 | 100         | web     |         1 |         150 | ... | 3904ef7a-551a-41f6-91e1-0374b910a3df
 2026-08-20 | 100         | web     |         2 |          50 | ... | 3904ef7a-551a-41f6-91e1-0374b910a3df
```

`fd5d56a3…`, the first run's id, appears **nowhere**. The stale rows are gone, not superseded.

---

## Phase 10 — Dump the deliverable

```bash
docker compose exec postgres psql -U app -d budget_biller_development \
  -c "\copy (SELECT date, merchant_id, channel, budget_id, engagements, premium_engagements, amount, billing_run_id FROM billed_stats ORDER BY date, merchant_id, channel, budget_id) TO STDOUT WITH CSV HEADER" \
  > billed_stats.csv
```

The result is [billed_stats.csv](billed_stats.csv) in this folder — all three provided files,
including the correction:

```csv
date,merchant_id,channel,budget_id,engagements,premium_engagements,amount,billing_run_id
2026-08-20,100,app,1,350,100,35.00,3904ef7a-551a-41f6-91e1-0374b910a3df
2026-08-20,100,web,1,150,0,15.00,3904ef7a-551a-41f6-91e1-0374b910a3df
2026-08-20,100,web,2,50,0,4.00,3904ef7a-551a-41f6-91e1-0374b910a3df
2026-08-20,200,app,0,0,100,0.00,9725840c-bbd6-4ade-9668-e89257b23f7d
2026-08-20,200,app,3,500,500,25.00,9725840c-bbd6-4ade-9668-e89257b23f7d
2026-08-21,100,app,2,150,0,12.00,93a12ad5-5b9c-43f7-9718-c6a51a53e44b
2026-08-21,200,web,3,80,0,4.00,3e375cee-5802-4c4e-91ef-8b5c9a375db6
```

Seven rows. Reading them as the two ledgers the brief defines:

| Date | engagements | premium_engagements |
|---|---|---|
| 2026-08-20 | `350 + 150 + 50 + 0 + 500` = **1050** ✅ | `100 + 0 + 0 + 100 + 500` = **700** ✅ |
| 2026-08-21 | `150 + 80` = **230** ✅ | `0 + 0` = **0** ✅ |

Row 4 is the unbilled bucket: `budget_id = 0`, `amount = 0.00`, `engagements = 0`,
`premium_engagements = 100`. It carries the premium overage and nothing else, which is precisely why
it lands in the second column's total without perturbing the first.

---

## Phase 11 — The test suite

⚠️ **The test database has to be created once.** It is a *separate* database
(`budget_biller_development_test`) so that the concurrency spec's truncation cleaner can never wipe
the development data you just produced the dump from. On a fresh volume it does not exist yet, and
`rspec` fails with `PG::ConnectionBad: database "budget_biller_development_test" does not exist`.
Run this first:

```bash
docker compose exec -e RAILS_ENV=test app bin/rails db:create db:schema:load
```

```
Created database 'budget_biller_development_test'
```

Then:

```bash
docker compose exec -e RAILS_ENV=test app bundle exec rspec
```

```
.................................

Finished in 1.66 seconds (files took 0.97392 seconds to load)
33 examples, 0 failures
```

The three that carry the Tier 2 pass bar, run on their own for legibility:

```bash
docker compose exec -e RAILS_ENV=test app bundle exec rspec spec/concurrency/billing_spec.rb --format documentation
```

```
billing under concurrency
  conserves both ledgers and never overfills a budget
  reclaims a batch whose lease expired, so a dead worker never blocks it forever
  fences out a stale lease-holder: it raises LeaseLost and commits nothing

Finished in 1.24 seconds (files took 0.92578 seconds to load)
3 examples, 0 failures
```

- **Example 1** is the pass bar itself: 4 real threads on a shared database, released together by a
  latch, driving **80 engagements against 35 units of capacity** — deliberately oversubscribed. It
  asserts I1 and I2 per date, I3 globally, *and* that `primary.fill == 25` and `fallback.fill == 10`
  exactly — capacity was genuinely exhausted, so the test actually reached the contended state
  instead of passing by never contending.
- **Example 2** is crash recovery without killing a process: a batch is claimed by `dead-worker`, a
  peer is shown to be correctly *refused* while the lease is live, the lease is then backdated, and
  the peer takes it over. No reaper process is involved — the claim predicate reclaims it.
- **Example 3** is the fencing token: a worker whose lease lapsed mid-batch raises `LeaseLost` at
  commit time and **nothing it did survives** — no `billed_stats` rows, no fill movement, batch still
  open for whoever legitimately holds it.

The development data is untouched by all of this:

```bash
docker compose exec postgres psql -U app -d budget_biller_development \
  -c "SELECT count(*) AS billed_stats_rows FROM billed_stats;" -c "SELECT id, fill FROM budgets ORDER BY id;"
```

```
 billed_stats_rows        id | fill
-------------------      ----+-------
                 7         1 | 50.00
                           2 | 16.00
                           3 | 29.00
```

---

## Phase 12 — Graceful shutdown

```bash
docker compose stop worker
```

```
16:59:47.305  (SIGTERM sent)
16:59:49.399  worker-3  {"event":"worker.stopped","worker_id":"ac54b6018d11-1"}
16:59:49.457  worker-1  {"event":"worker.stopped","worker_id":"c2692c803e9f-1"}
16:59:49.511  worker-2  {"event":"worker.stopped","worker_id":"8f075844ff33-1"}
```

All three logged `worker.stopped` — they exited *through* their own signal handler, not by being
killed. The loop traps `TERM`/`INT`, stops claiming new batches, finishes the one in flight, and
returns. `stop_grace_period: 30s` in `docker-compose.yml` is what buys the time. Without this, every
`compose down` would strand a batch as `claimed` until its 60-second lease lapsed — recoverable, but
needlessly slow, and it would inflate `attempts` toward the poison-pill bound for no reason.

Tear down:

```bash
docker compose down      # containers go, volumes (and your data) survive
docker compose down -v   # also destroy pgdata — deliberate, wipes everything
```

---

## The whole thing, copy-paste

```bash
# 0. build
cp .env.example .env
docker compose down -v            # only if you want a guaranteed-clean slate
docker compose build

# 1-2. infrastructure, schema, seed budgets
docker compose up -d postgres app
docker compose exec app bin/rails db:create db:migrate db:seed

# 3. ingest
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-20.csv]"
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-21.csv]"

# 4. (optional) ingest idempotency — re-run one and watch nothing change
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-20.csv]"

# 5-6. bill, on a schedule, with no trigger
docker compose up -d --scale worker=3
docker compose logs -f worker                       # ctrl-C once it goes quiet
docker compose exec app bin/rails billing:verify

# 8-9. reconciliation — the workers stay up and pick it up themselves
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-20_v2.csv]"
docker compose exec app bin/rails billing:verify

# 10. the deliverable
docker compose exec postgres psql -U app -d budget_biller_development \
  -c "\copy (SELECT date, merchant_id, channel, budget_id, engagements, premium_engagements, amount, billing_run_id FROM billed_stats ORDER BY date, merchant_id, channel, budget_id) TO STDOUT WITH CSV HEADER" \
  > billed_stats.csv

# 11. tests (the first line is one-time, on a fresh volume)
docker compose exec -e RAILS_ENV=test app bin/rails db:create db:schema:load
docker compose exec -e RAILS_ENV=test app bundle exec rspec

# 12. shutdown
docker compose stop worker
docker compose down
```

**Scripted variant.** If you would rather not wait on the poll loop, `billing:drain` bills until no
work remains and exits — same code path, no worker containers:

```bash
docker compose exec app bin/rails billing:drain
```

---

## Scoreboard against the brief

| Rule | Where it was demonstrated | Evidence |
|---|---|---|
| 1 — Charge = `engagements × rate`, `fill < quota` | Phase 5 | B1 `0 → 40.00 → 50.00`, stops at quota |
| 2 — Fallback, then unbilled bucket | Phase 5 | `(B1, web, 100)` + `(B2, web, 100)`; sentinel `budget_id = 0` row |
| 3 — Ingest idempotency | Phase 4 | 5 staging rows after 3 file loads; digests unmoved |
| 4 — Billing idempotency, no manual trigger | Phase 7 | `attempts`/`billed_at`/`billing_run_id` identical across 15s of polling |
| 5 — Atomic concurrent claim | Phase 5 | Overlapping claims 12 ms apart, disjoint batches, `attempts = 1` everywhere |
| 6 — Atomic fill | Phase 6 | `fill == quota` exactly on B1 and B2; `CHECK (fill <= quota)` never tripped |
| 7 — Crash recovery | Phase 11 | `reclaims a batch whose lease expired` + `fences out a stale lease-holder` |
| 8 — Prove it (2+ concurrent workers) | Phase 5 + 11 | 3 worker containers live; 4-thread spec on oversubscribed capacity |
| 9 — Overage split | Phase 5, Phase 10 | `(2026-08-20, 200, app, budget 0, 0 eng, 100 premium, 0.00)` |
| 10 — Reconciliation | Phase 8 | `reversed_rows: 3`, `attempts: 2`, run `fd5d56a3…` gone from the table |
| I1 / I2 / I3 | Phases 6 + 9 | `billing:verify` green before *and* after the correction |

## Where to read next

- [../../README.md](../../README.md) — the design: concurrency mechanism, trade-offs, decisions
- [../Docker/README.md](../Docker/README.md) — container reference and the daily-use command list
- [../infrastructure/03-concepts-implemented.md](../infrastructure/03-concepts-implemented.md) — each concept above, with the code that implements it
- [run-timeline.md](run-timeline.md) — the raw log, timestamped
