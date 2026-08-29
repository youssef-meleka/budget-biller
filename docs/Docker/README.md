# Docker

This app has no host Ruby toolchain assumption at all — Docker is the only place it runs. This
document covers what the container setup provides, what each file does, and the commands for both
first-time setup and day-to-day use.

## What it provides

Three services, one shared image for two of them:

```
┌─────────────┐     ┌─────────────┐
│     app     │     │   worker    │   (same image, different command)
│ sleep       │     │ billing:work│
│ infinity    │     │ (scalable)  │
└──────┬──────┘     └──────┬──────┘
       │                   │
       └─────────┬─────────┘
                  │
           ┌──────▼──────┐
           │  postgres   │
           │ 16-alpine   │
           └─────────────┘
```

- **`app`** — an idle shell (`sleep infinity`) you `exec` into to run rake tasks, migrations, and
  specs. It isn't a long-running process of its own; it's a stable place to run one-off commands.
- **`worker`** — runs the billing loop (`bin/rails billing:work`) and is the service meant to be
  scaled to multiple replicas to prove the concurrency mechanism works.
- **`postgres`** — the datastore, with a healthcheck so `app`/`worker` never race the database's
  own startup.

There is no web/HTTP service and no Redis — this app has no HTTP surface, and the database itself
acts as the work queue (see `docs/infrastructure/02-technology-choices.md` for why).

## Files

| File | What it does |
|---|---|
| `docker-compose.yml` | Defines the three services above, their environment variables (sourced from `.env`), volumes, and the bridge network they share. `RAILS_MAX_THREADS`, `BILLING_POLL_INTERVAL`, and `BILLING_LEASE_TTL` are all injected here, so this file is also the map of what's configurable. |
| `docker/app/Dockerfile` | Builds the one image both `app` and `worker` run from: Ruby 3.3 slim base, native build dependencies for `libpq` (the Postgres client library), gems bundled into their own cached layer, and a non-root user created to match the host's `UID`/`GID` so bind-mounted files stay editable outside the container. No `EXPOSE`, no server — the default command is just a shell. |
| `.dockerignore` | Keeps `.git`, `tmp`, and other local-only files out of the build context, so the image build stays fast and small. |
| `.env.example` / `.env` | The single source of configuration: database credentials, the forwarded Postgres port, `UID`/`GID` for the non-root user, and the billing tunables (`BILLING_POLL_INTERVAL`, `BILLING_LEASE_TTL`, `BILLING_MAX_ATTEMPTS`). `.env.example` is committed and documents every variable; `.env` is your local copy and is git-ignored. |

Two named volumes back everything: `pgdata` (the database's actual files, so data survives
`docker compose down`) and `bundle_cache` (installed gems, so a rebuild doesn't re-download the
whole bundle every time).

## First-time setup

Run these once, in order:

```bash
cp .env.example .env                       # then edit UID/GID inside if your host isn't 1000:1000
docker compose build                       # builds the shared app/worker image
docker compose up -d postgres app          # starts the database and the app shell
docker compose exec app bin/rails db:create db:migrate db:seed
```

At this point the schema exists and the three seed budgets are loaded with `fill = 0.00`. Ingest
the sample data and let the workers bill it:

```bash
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-20.csv]"
docker compose exec app bin/rails "billing:ingest[data/stats_2026-08-21.csv]"
docker compose up -d --scale worker=3      # workers claim and bill on their own
docker compose exec app bin/rails billing:verify   # confirms the invariants hold
```

Finally, confirm the test suite passes against its own database. The test suite runs against a
separate database (`_test`-suffixed — see the note below), which does not exist yet on a fresh
volume, so it needs to be created once:

```bash
docker compose exec -e RAILS_ENV=test app bin/rails db:create db:schema:load
docker compose exec -e RAILS_ENV=test app bundle exec rspec
```

## Daily-use commands

**Start / stop**
```bash
docker compose up -d postgres app          # bring the database and app shell up
docker compose up -d --scale worker=3      # (re)start N worker replicas
docker compose stop                        # stop containers, keep volumes
docker compose down                        # remove containers, keep volumes (data survives)
docker compose down -v                     # also destroy volumes — wipes the database, use deliberately
```

**Run billing work**
```bash
docker compose exec app bin/rails "billing:ingest[data/some_file.csv]"   # load a CSV
docker compose exec app bin/rails billing:drain                          # bill until no work remains, then exit
docker compose exec app bin/rails billing:verify                         # check the conservation invariants
```

**Tests**
```bash
docker compose exec -e RAILS_ENV=test app bundle exec rspec
docker compose exec -e RAILS_ENV=test app bundle exec rspec spec/concurrency/billing_spec.rb
```

**Logs**
```bash
docker compose logs -f worker              # tail all worker replicas
docker compose logs -f --tail=100 app
```

**Database access**
```bash
docker compose exec postgres psql -U app -d budget_biller_development

# dump billed_stats to CSV on the host:
docker compose exec postgres psql -U app -d budget_biller_development \
  -c "\copy (SELECT * FROM billed_stats ORDER BY date, merchant_id, channel, budget_id) TO STDOUT WITH CSV HEADER" \
  > billed_stats.csv
```

**A shell inside the app container**
```bash
docker compose exec app bash
docker compose exec app bin/rails console
```

**After changing the Gemfile or Dockerfile**
```bash
docker compose build app                   # rebuild the image
docker compose up -d --scale worker=3      # recreate containers from the new image
```

## Notes worth knowing

- `worker` waits on `app: condition: service_started` and `postgres: condition: service_healthy`
  before starting, so `docker compose up` brings services up in the right order on its own.
- `worker` has a 30-second `stop_grace_period` — on `docker compose down`/`stop`, it has time to
  finish an in-flight batch (graceful shutdown, see `docs/infrastructure/03-concepts-implemented.md`)
  before being killed.
- The test suite runs against a separate database (derived from `DATABASE_URL` with a `_test`
  suffix), so running specs never truncates your development data.
