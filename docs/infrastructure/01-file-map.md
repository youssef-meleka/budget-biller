# File Map — What Every Piece Of This App Does

Budget Biller is a batch billing pipeline, not a web app — there is no HTTP surface. The flow is:
CSV files of merchant "engagement" data get ingested into a staging table, then a pool of
concurrent worker processes claim `(date, merchant_id)` batches one at a time and allocate each
batch's engagements against that merchant's budgets (with overflow spilling to a fallback budget,
and any leftover going into an "unbilled" bucket). Everything runs in Docker: Rails 7.2 / Ruby 3.3
for the app, PostgreSQL 16 for storage — and PostgreSQL's row locking (`FOR UPDATE SKIP LOCKED`) is
the actual concurrency mechanism, not a job queue or Redis.

The design leans on the database as the source of truth for correctness: claims are one atomic
`UPDATE ... RETURNING`, charges are guarded conditional updates under a row lock, and everything is
backed by `CHECK` constraints and unique indexes so that even a buggy caller can't corrupt the
ledger. [`README.md`](../../README.md) documents the reasoning behind every one of these decisions
in detail.

## Top-level layout

| Folder | Purpose |
|---|---|
| `app/models/` | ActiveRecord models — thin, mostly just validations. No business logic lives here. |
| `app/services/` | Where all the actual logic lives: ingest parsing and the billing pipeline (claim → allocate → persist → reconcile). |
| `config/` | Rails app config, environments, and the one initializer for billing-related ENV vars. |
| `db/` | Migrations, the generated schema, and the seed script. |
| `lib/tasks/` | Rake tasks — the only way this app is ever invoked (`ingest`, `work`, `drain`, `verify`). |
| `docker/` + `docker-compose.yml` | Container definitions: one Dockerfile, three compose services (app, worker, postgres). |
| `spec/` | RSpec test suite — unit, acceptance, and a real multi-threaded concurrency spec. |
| `data/` | The task's raw input data — sample CSVs (budgets + engagement stats) and the expected worked-examples output, used by seeds, specs, and manual runs. |
| `bin/` | Rails' standard executable wrapper. |

## `app/models/` — data + constraints, no logic

| File | Purpose |
|---|---|
| `application_record.rb` | Standard Rails abstract base class. |
| `budget.rb` | A merchant's spending pool: `rate`, `quota`, running `fill`, optional `fallback_budget_id` (self-referential — where overflow spills to). Validations mirror the database check constraints. |
| `pending_engagement.rb` | One staged CSV row: `date` / `merchant_id` / `channel` / `engagements` / `premium_engagements`, plus provenance (`source_file`). This is the ingest landing table. |
| `billing_batch.rb` | The unit of work — one row per `(date, merchant_id)`. Has the `state` enum (`pending`/`claimed`/`billed`/`failed`) and the `eligible` scope, which is the single predicate that makes both "bill new data" and "re-bill a correction" the same code path. |
| `billed_stat.rb` | Output ledger row: what actually got billed, to which budget, for how much. `budget_id = 0` is a sentinel for "unbillable." |

## `app/services/` — the actual pipeline

| File | Purpose |
|---|---|
| `ingest/load_file.rb` | CSV → `pending_engagements`. Parses with `Integer`/`BigDecimal` (never `to_f`), upserts on the natural key `(date, merchant_id, channel)` so re-ingesting a corrected file overwrites rather than duplicates, then recomputes a `staging_digest` hash per batch — that digest is what flags a batch as needing re-billing. |
| `billing/allocator.rb` | **The pure functional core.** No ActiveRecord, no database, no clock — just plain objects in, plain objects out. Given one engagement record and a set of budget snapshots, it walks the fallback chain, computes how many engagements each budget can afford (`floor`, never `round`), splits premium engagements fill-first, and asserts conservation before returning. Because it's pure, its spec runs without Rails or a database at all. |
| `billing/claim_batch.rb` | The atomic claim: one `UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED) RETURNING *`. This is what lets N worker processes each grab a different batch instead of piling onto one row. |
| `billing/bill_batch.rb` | **The imperative shell.** Claims a batch, locks that merchant's budgets (ascending id order — deadlock avoidance), calls the reconciler if needed, snapshots budgets, runs the allocator per staged record, persists `billed_stats`, charges budgets with a guarded database-side `UPDATE`, and fences the final commit so a lease-expired worker can't clobber a peer's work. Also handles retryable errors (deadlocks, races) vs. terminal ones. |
| `billing/reconcile.rb` | The correction path. When a CSV correction changes a batch's digest, this reverses the prior run's `billed_stats` rows and refunds the budget `fill` — in the *same transaction* as the re-bill that follows, so there's no window where the budget looks emptier than it is. |
| `billing/conservation_check.rb` | Executable version of the three invariants (engagements conserved, premium engagements conserved, no budget over quota). Runs against live database state — this is what `billing:verify` calls, and what every spec's `after` hook checks. |
| `billing/errors.rb` | The typed error hierarchy: `CapacityRaced`, `ConservationViolation`, `MalformedBatch`, `LeaseLost` — each with a documented "expected vs. bug" meaning that `bill_batch.rb` branches on. |

## `config/`

| File | Purpose |
|---|---|
| `application.rb` | Rails app definition. Notably strips out unused frameworks (no `action_controller`/`action_view`/etc. — there's no HTTP surface), and explicitly excludes `allocator.rb`/`errors.rb` from Zeitwerk autoloading (they define multiple constants per file, which Zeitwerk can't infer). |
| `boot.rb`, `environment.rb` | Standard Rails boot sequence. |
| `database.yml` | Reads `DATABASE_URL` from the environment; test env derives its own database name (`..._test`) so the concurrency spec's table-truncation never touches development data. |
| `environments/development.rb`, `environments/test.rb`, `environments/production.rb` | Standard per-environment Rails settings. |
| `initializers/billing.rb` | The single place all billing-related `ENV` vars are read: poll interval, lease TTL, max retry attempts. |

## `db/`

| File | Purpose |
|---|---|
| `migrate/20260101000001_create_budgets.rb` | `budgets` table + check constraints (`fill <= quota`, `fill >= 0`, `rate > 0`, etc.) — the "no overfill" invariant is enforced at the database level, not just in Ruby. |
| `migrate/20260101000002_create_pending_engagements.rb` | `pending_engagements` staging table + the unique index on `(date, merchant_id, channel)` that makes ingest idempotent. |
| `migrate/20260101000003_create_billing_batches.rb` | `billing_batches` table, the `state`/`lease_expires_at` index the claim query depends on, and the state check constraint. |
| `migrate/20260101000004_create_billed_stats.rb` | `billed_stats` output table + the unique index that is the actual double-billing guard. No foreign key on `budget_id` (the sentinel `0` for unbillable rows would be rejected by one). |
| `schema.rb` | Rails' generated current-state snapshot of the schema — not hand-edited. |
| `seeds.rb` | Loads the three seed budgets from `data/budgets.csv`, in two passes (so `fallback_budget_id` can reference a row inserted later in the same file). |

## `lib/tasks/`

| File | Purpose |
|---|---|
| `billing.rake` | Four entry points: `billing:ingest[path]` (load a CSV), `billing:work` (the long-running worker loop, with `SIGTERM`/`SIGINT` graceful shutdown), `billing:drain` (work until nothing's left, then exit — used by specs and scripted runs), `billing:verify` (run the conservation check and exit non-zero on violation). |

## `docker/` + compose

| File | Purpose |
|---|---|
| `docker/app/Dockerfile` | Ruby 3.3 slim image, bundles gems in their own layer for caching, creates a non-root user matching the host's UID/GID (so bind-mounted files stay editable), no `EXPOSE` since there's no server. |
| `docker-compose.yml` | Three services: `app` (idle shell for running rake tasks / specs), `worker` (runs `billing:work`, meant to be scaled with `--scale worker=N`), `postgres` (16-alpine with a healthcheck). No Redis/queue service — the database claim mechanism replaces one. |
| `.dockerignore` | Standard build-context excludes. |

## `spec/`

| File | Purpose |
|---|---|
| `rails_helper.rb`, `spec_helper.rb` | Standard RSpec/Rails boot config; notably enables `DatabaseCleaner.allow_remote_database_url` since compose's Postgres is treated as "remote" by default. |
| `services/billing/allocator_spec.rb` | Unit tests for the pure allocator — every fallback/exhaustion/boundary/conservation case, millisecond-fast since there's no database involved. |
| `services/ingest/load_file_spec.rb` | Confirms CSV parsing, upsert idempotency, and batch-touching behavior. |
| `acceptance/worked_examples_spec.rb` | End-to-end: seeds the real budgets, ingests the real sample files, drains the worker, and asserts the output matches `data/worked-examples.md` exactly. |
| `acceptance/reconciliation_spec.rb` | Same idea, but for the correction flow — ingesting a corrected file and confirming stale rows are gone and budgets are refunded correctly. |
| `concurrency/billing_spec.rb` | The one that actually proves the concurrency claims: 4 real OS threads hitting a shared Postgres, released together by a latch, with real table truncation between runs. Asserts the invariants hold and capacity was genuinely exhausted, not just under-contended. |

## `data/`

The task's raw input data: `budgets.csv` (seed data for the `budgets` table) and the engagement
stats files (`stats_2026-08-20.csv`, its correction `stats_2026-08-20_v2.csv`, and
`stats_2026-08-21.csv`), plus `worked-examples.md` — the expected-output reference the acceptance
spec checks against.

---

One thing worth flagging: essentially every non-trivial decision in this codebase is documented as
a code comment near where it's implemented. If you want the *why* behind something rather than just
the *what*, start with [`README.md`](../../README.md) — it walks through the concurrency mechanism,
idempotency design, and every trade-off made along the way.
