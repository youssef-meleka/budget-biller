# Run Timeline — in-process logs, timestamped

Raw capture of the run narrated in [README.md](README.md). Every line below came out of a real
container on **2026-08-28**. Nothing is reconstructed.

- `T0 = 16:56:52.605Z` — the moment `docker compose up -d postgres app` was issued
- `T+` columns are elapsed seconds from `T0`
- Worker lines are `docker compose logs -t worker` output, re-sorted into strict chronological order
  (compose interleaves per-container, so the raw stream is grouped by replica, not by time)
- The app logs JSON to STDOUT by design (`config.logger = ActiveSupport::Logger.new($stdout)` in
  `config/environments/development.rb`), so `docker compose logs` is the single place to look

How this was captured:

```bash
docker compose logs -t --no-color worker | sort -k3     # chronological across replicas
docker compose logs -f worker                           # live tail while it runs
```

---

## Master timeline

| T+ | UTC | Source | Event |
|---:|---|---|---|
| `00.000` | `16:56:52.605` | host | `docker compose up -d postgres app` |
| `07.946` | `16:57:00.551` | compose | postgres **healthy**, app started |
| `08.075` | `16:57:00.680` | app | `db:create db:migrate db:seed` begins |
| `09.681` | `16:57:02.286` | app | 4 migrations applied, 3 budgets seeded — **1.6s** |
| `21.421` | `16:57:14.026` | psql | budgets confirmed: B1/B2/B3, all `fill = 0.00` |
| `21.625` | `16:57:14.230` | app | ingest `stats_2026-08-20.csv` begins |
| `22.800` | `16:57:15.405` | app | `{"event":"ingest.completed","rows":3,"batches":2}` — **1.2s** |
| `22.800` | `16:57:15.405` | app | ingest `stats_2026-08-21.csv` begins |
| `23.912` | `16:57:16.517` | app | `{"event":"ingest.completed","rows":2,"batches":2}` — **1.1s** |
| `24.073` | `16:57:16.678` | psql | staging: 5 rows, 4 batches, all `pending`, no `billed_digest` |
| `37.067` | `16:57:29.672` | app | **idempotency probe** — re-ingest `stats_2026-08-20.csv` |
| `38.404` | `16:57:31.009` | psql | still 5 staging rows; all 4 digests unchanged ✅ |
| `38.404` | `16:57:31.009` | host | `docker compose up -d --scale worker=3` |
| `40.400` | `16:57:33.005` | compose | worker-1, worker-2, worker-3 started |
| `41.022` | `16:57:33.627` | **worker-3** | `worker.started` |
| `41.212` | `16:57:33.817` | **worker-1** | `worker.started` |
| `41.389` | `16:57:33.994` | **worker-3** | `batch.claimed` `(2026-08-20, 100)` lease → `16:58:33.949` |
| `41.398` | `16:57:34.003` | **worker-2** | `worker.started` |
| `41.528` | `16:57:34.133` | **worker-3** | `batch.billed` `(2026-08-20, 100)` `allocations:3 amount:58.0` |
| `41.539` | `16:57:34.144` | **worker-3** | `batch.claimed` `(2026-08-21, 100)` |
| `41.551` | `16:57:34.156` | **worker-1** | `batch.claimed` `(2026-08-20, 200)` ← **concurrent, disjoint** |
| `41.557` | `16:57:34.162` | **worker-3** | `batch.billed` `(2026-08-21, 100)` `allocations:1 amount:12.0` |
| `41.564` | `16:57:34.169` | **worker-3** | `batch.claimed` `(2026-08-21, 200)` |
| `41.591` | `16:57:34.196` | **worker-3** | `batch.billed` `(2026-08-21, 200)` `allocations:1 amount:4.0` |
| `41.688` | `16:57:34.293` | **worker-1** | `batch.billed` `(2026-08-20, 200)` `allocations:2 amount:25.0` |
| `52.405` | `16:57:45.010` | host | queue drained; workers idle at 5s poll |
| `64.611` | `16:57:57.216` | app | `billing:verify` → **conservation OK** |
| `65.771` | `16:57:58.376` | psql | fills `B1 50.00 / B2 20.00 / B3 29.00`; 7 `billed_stats` rows |
| `84.383` | `16:58:16.988` | psql | idempotency snapshot #1 |
| `99.574` | `16:58:32.179` | psql | idempotency snapshot #2, after 15s / ~9 poll cycles — **identical** ✅ |
| `99.762` | `16:58:32.367` | app | ingest **correction** `stats_2026-08-20_v2.csv` begins |
| `101.155` | `16:58:33.760` | app | `{"event":"ingest.completed","rows":3,"batches":2}`; digest `7e89b9… → 9525b8…` |
| `101.664` | `16:58:34.269` | **worker-3** | `batch.claimed` `(2026-08-20, 100)` `attempts:2` ← **1.9s after ingest, unprompted** |
| `101.710` | `16:58:34.315` | **worker-3** | `batch.billed` `amount:54.0` **`reversed_rows:3`** — **46 ms** |
| `113.161` | `16:58:45.766` | host | workers idle again |
| `129.148` | `16:59:01.753` | app | `billing:verify` → **conservation OK** (post-correction) |
| `130.239` | `16:59:02.844` | psql | fills `B1 50.00 / B2 16.00 / B3 29.00` — matches worked examples |
| `142.540` | `16:59:15.145` | psql | `\copy billed_stats → billed_stats.csv`, 7 rows |
| `156.778` | `16:59:29.383` | app | `RAILS_ENV=test db:create db:schema:load` → `Created database 'budget_biller_development_test'` |
| `158.156` | `16:59:30.761` | app | `rspec` begins |
| `161.128` | `16:59:33.733` | app | **33 examples, 0 failures** in 1.66s (0.97s load) |
| `171.982` | `16:59:44.587` | app | `rspec spec/concurrency/billing_spec.rb` → **3 examples, 0 failures** in 1.24s |
| `174.554` | `16:59:47.159` | psql | dev data untouched by the test run: still 7 rows, fills unchanged ✅ |
| `174.700` | `16:59:47.305` | host | `docker compose stop worker` — SIGTERM |
| `176.794` | `16:59:49.399` | **worker-3** | `worker.stopped` |
| `176.852` | `16:59:49.457` | **worker-1** | `worker.stopped` |
| `176.906` | `16:59:49.511` | **worker-2** | `worker.stopped` |

**Total elapsed: 2 minutes 56.9 seconds.**

---

## Raw worker log

Exactly as `docker compose logs -t --no-color worker | sort -k3` produced it — full JSON, nothing
elided:

```
worker-3  2026-08-28T16:57:33.627467948Z {"event":"worker.started","worker_id":"ac54b6018d11-1"}
worker-1  2026-08-28T16:57:33.817425485Z {"event":"worker.started","worker_id":"c2692c803e9f-1"}
worker-3  2026-08-28T16:57:33.994655949Z {"event":"batch.claimed","run_id":"d5aa77a5-e554-4221-bbc7-1c46dd908ec8","worker_id":"ac54b6018d11-1","date":"2026-08-20","merchant_id":"100","attempts":1,"lease_expires_at":"2026-08-28T16:58:33.949Z"}
worker-2  2026-08-28T16:57:34.003527930Z {"event":"worker.started","worker_id":"8f075844ff33-1"}
worker-3  2026-08-28T16:57:34.133498655Z {"event":"batch.billed","run_id":"d5aa77a5-e554-4221-bbc7-1c46dd908ec8","worker_id":"ac54b6018d11-1","date":"2026-08-20","merchant_id":"100","attempts":1,"allocations":3,"amount":"58.0","billing_run_id":"fd5d56a3-9d09-47ce-8376-278a0ea6f9b4","reversed_rows":0}
worker-3  2026-08-28T16:57:34.144208394Z {"event":"batch.claimed","run_id":"d5aa77a5-e554-4221-bbc7-1c46dd908ec8","worker_id":"ac54b6018d11-1","date":"2026-08-21","merchant_id":"100","attempts":1,"lease_expires_at":"2026-08-28T16:58:34.139Z"}
worker-1  2026-08-28T16:57:34.156663607Z {"event":"batch.claimed","run_id":"b08313ee-d2cd-468b-a471-a879b1bcfb1f","worker_id":"c2692c803e9f-1","date":"2026-08-20","merchant_id":"200","attempts":1,"lease_expires_at":"2026-08-28T16:58:34.114Z"}
worker-3  2026-08-28T16:57:34.162227249Z {"event":"batch.billed","run_id":"d5aa77a5-e554-4221-bbc7-1c46dd908ec8","worker_id":"ac54b6018d11-1","date":"2026-08-21","merchant_id":"100","attempts":1,"allocations":1,"amount":"12.0","billing_run_id":"93a12ad5-5b9c-43f7-9718-c6a51a53e44b","reversed_rows":0}
worker-3  2026-08-28T16:57:34.169033296Z {"event":"batch.claimed","run_id":"d5aa77a5-e554-4221-bbc7-1c46dd908ec8","worker_id":"ac54b6018d11-1","date":"2026-08-21","merchant_id":"200","attempts":1,"lease_expires_at":"2026-08-28T16:58:34.166Z"}
worker-3  2026-08-28T16:57:34.196723658Z {"event":"batch.billed","run_id":"d5aa77a5-e554-4221-bbc7-1c46dd908ec8","worker_id":"ac54b6018d11-1","date":"2026-08-21","merchant_id":"200","attempts":1,"allocations":1,"amount":"4.0","billing_run_id":"3e375cee-5802-4c4e-91ef-8b5c9a375db6","reversed_rows":0}
worker-1  2026-08-28T16:57:34.293631578Z {"event":"batch.billed","run_id":"b08313ee-d2cd-468b-a471-a879b1bcfb1f","worker_id":"c2692c803e9f-1","date":"2026-08-20","merchant_id":"200","attempts":1,"allocations":2,"amount":"25.0","billing_run_id":"9725840c-bbd6-4ade-9668-e89257b23f7d","reversed_rows":0}
worker-3  2026-08-28T16:58:34.269524338Z {"event":"batch.claimed","run_id":"d5aa77a5-e554-4221-bbc7-1c46dd908ec8","worker_id":"ac54b6018d11-1","date":"2026-08-20","merchant_id":"100","attempts":2,"lease_expires_at":"2026-08-28T16:59:34.259Z"}
worker-3  2026-08-28T16:58:34.315981919Z {"event":"batch.billed","run_id":"d5aa77a5-e554-4221-bbc7-1c46dd908ec8","worker_id":"ac54b6018d11-1","date":"2026-08-20","merchant_id":"100","attempts":2,"allocations":3,"amount":"54.0","billing_run_id":"3904ef7a-551a-41f6-91e1-0374b910a3df","reversed_rows":3}
worker-3  2026-08-28T16:59:49.399996141Z {"event":"worker.stopped","worker_id":"ac54b6018d11-1"}
worker-1  2026-08-28T16:59:49.457827193Z {"event":"worker.stopped","worker_id":"c2692c803e9f-1"}
worker-2  2026-08-28T16:59:49.511860248Z {"event":"worker.stopped","worker_id":"8f075844ff33-1"}
```

Sixteen lines for the entire run. That is the point: the log is an **event stream**, not a debug
trace. Every line is a state transition someone would want to audit, and each is a single JSON
object, so `docker compose logs worker | jq 'select(.event=="batch.billed")'` works directly.

### Field reference

| Field | Meaning |
|---|---|
| `event` | `worker.started` · `batch.claimed` · `batch.billed` · `worker.stopped`. Failure paths add `batch.capacity_raced`, `batch.lease_lost`, `batch.deadlocked`, `batch.already_billed`, `batch.failed` — none fired in this run |
| `run_id` | Per-**process** id, memoised once. Groups every line from one worker container across its whole lifetime |
| `worker_id` | `hostname-pid` — the value written to `billing_batches.claimed_by` and asserted by the fencing check |
| `date`, `merchant_id` | The batch key. This *is* the unit of claiming |
| `attempts` | Incremented **by the claim statement itself**, in the same UPDATE. Bounded by `BILLING_MAX_ATTEMPTS=5`, after which the batch goes terminally `failed` |
| `lease_expires_at` | `NOW() + 60s`, computed **by Postgres**. Never `Time.current` — three replicas have three drifting clocks, the database has one |
| `allocations` | `billed_stats` rows written. Exceeds the input row count whenever a record splits across a fallback or into the unbilled bucket |
| `amount` | Total charged to real budgets this batch. Sentinel (`budget_id = 0`) rows contribute `0.00` |
| `billing_run_id` | Fresh UUID **per bill attempt**. This is the reconciliation key: rows not carrying the current run's id are, by definition, stale |
| `reversed_rows` | Stale rows deleted and reversed out of `fill` before the re-bill, in the same transaction. `0` on a first bill |

---

## Four moments worth reading closely

### 1 — `SKIP LOCKED`, visible in 12 milliseconds

```
16:57:34.144  worker-3  batch.claimed  (2026-08-21, 100)
16:57:34.156  worker-1  batch.claimed  (2026-08-20, 200)     <- 12 ms later, different batch
```

worker-1 arrived while worker-3 held a row lock inside its claim statement. It did **not** wait: it
skipped the locked candidate and took the next eligible row. Without `SKIP LOCKED`, worker-1 blocks
here and the replicas serialise into a single-file queue — the system would still be *correct*, but
scaling it would buy nothing.

The claim is one statement, which is what makes it atomic:

```sql
UPDATE billing_batches SET state='claimed', claimed_by=?, lease_expires_at=NOW()+..., attempts=attempts+1
 WHERE id = (SELECT id FROM billing_batches WHERE <eligible> ORDER BY date, merchant_id
             LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING *
```

There is no window between the read and the write for a second worker to slip into. Contrast a
check-then-set boolean — `SELECT … WHERE claimed = false` then `UPDATE … SET claimed = true` — where
that window is exactly where double-billing lives.

### 2 — Fifteen seconds of polling that changed nothing

Between `16:58:16.988` and `16:58:32.179` three replicas polled at 5-second intervals — roughly nine
claim attempts — and the log is **empty**. `attempts`, `billed_at` and `billing_run_id` were
byte-identical across the two snapshots.

The reason there is no log line is the design: the workers did not claim-then-discover-then-skip.
The eligibility predicate lives inside the claim's `WHERE`, so a settled batch
(`state='billed' AND staging_digest = billed_digest`) is simply never returned. Idempotency here is
an absence of work, not a rejected unit of work.

### 3 — The correction, picked up on the poll boundary

```
16:58:32.367   ingest of stats_2026-08-20_v2.csv begins
16:58:33.760   ingest completes; staging_digest 7e89b9… → 9525b8…
16:58:34.269   worker-3  batch.claimed  (2026-08-20, 100)  attempts:2
16:58:34.315   worker-3  batch.billed   amount:54.0  reversed_rows:3
```

worker-3's poll cycle had been landing on `:34.2` every five seconds since `16:57:34.196`
(`34.2 → 39.2 → 44.2 → … → 16:58:34.2`). The ingest finished at `:33.76`; the very next tick,
**0.5 s later**, found the batch newly eligible and took it. **No trigger, no restart, no
reconciliation command** — the ingest changed a digest, and the digest is the queue.

`reversed_rows: 3` and the new `billing_run_id` are the compensating transaction: the three rows
from run `fd5d56a3…` were deleted and their amounts subtracted from `fill` **inside the same
transaction** that wrote run `3904ef7a…`. 46 milliseconds, and at no instant in between did the
budgets look free to another worker.

`(2026-08-20, 200)` produced no log line at all — same date, but its digest never moved, so it was
never eligible. Reconciliation is scoped to the batches whose data actually changed.

### 4 — Graceful shutdown, all three replicas

```
16:59:47.305  SIGTERM sent by `docker compose stop worker`
16:59:49.399  worker-3  worker.stopped
16:59:49.457  worker-1  worker.stopped
16:59:49.511  worker-2  worker.stopped
```

Every replica emitted `worker.stopped` — they returned from their own loop rather than being killed.
`Signal.trap("TERM")` flips a flag; the loop stops claiming, finishes anything in flight, and exits.
All three were out in **~2.1 s**, comfortably inside the `stop_grace_period: 30s` that
`docker-compose.yml` grants for a long in-flight batch.

Had they been SIGKILLed instead, correctness would still hold — the lease expires after 60s and a
peer reclaims the batch (`spec/concurrency/billing_spec.rb`, example 2, proves exactly this). But
every deploy would then cost a 60-second stall per in-flight batch and burn one of the five
`attempts`. Graceful shutdown is a latency and hygiene property here, not a correctness one.

---

## Events that did *not* fire, and what would produce them

The absence is worth as much as the presence — this run had no contention pathology to report.

| Event | What triggers it |
|---|---|
| `batch.capacity_raced` | A peer consumed budget capacity between the locked read and the guarded `UPDATE … WHERE fill + ? <= quota`. Expected under real contention, not a bug — the batch simply stays eligible and is retried |
| `batch.lease_lost` | A worker paused past its 60s lease and lost the fencing check at commit. Its whole transaction rolls back |
| `batch.deadlocked` | Two workers grabbed the same budget rows in opposing order. Mitigated by locking `ORDER BY id` ascending, and retried up to 3 times with jittered backoff |
| `batch.already_billed` | The unique index on `billed_stats (date, merchant, channel, budget)` rejected a duplicate. The correctness *boundary*, beneath the eligibility fast path |
| `batch.failed` | Terminal, at `attempts >= 5`. Deliberately leaves a loud conservation imbalance rather than letting a batch vanish quietly |

To see the first three on demand, run the specs — they induce each one directly:

```bash
docker compose exec -e RAILS_ENV=test app bundle exec rspec spec/concurrency/billing_spec.rb --format documentation
```

## Reproducing this capture

```bash
docker compose down -v && docker compose build          # guaranteed-clean slate
# ... follow the phases in README.md ...
docker compose logs -t --no-color worker | sort -k3     # this file's raw section
```

Timestamps will differ; the **ordering, the counts, the amounts, the digests-diverging-once and the
final fills will not**.
