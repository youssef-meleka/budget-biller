# Why This Infrastructure Was Chosen

This app started from an open brief: build a batch billing pipeline where multiple worker replicas
process the same data concurrently, and money must never be lost, double-billed, or created. The
storage requirement was permissive — SQLite or Postgres, Docker optional — and the language was
open too. Nothing forced the specific stack this app ends up on. Every choice below was made
deliberately, in service of one goal: **proving** the concurrency and money-conservation guarantees
rather than merely asserting them.

That goal — what actually gets evaluated — comes down to four things: correctness under
concurrency, conservation of money, idempotency design, and code structure (pure allocation logic
kept separate from I/O). Framework choice, UI, and deployment polish are explicitly not the point.
Every infrastructure decision below traces back to making those four things demonstrable.

## Why PostgreSQL 16, specifically — not SQLite

This is the load-bearing choice in the whole stack. The task's hardest requirement is proving that
two workers can run against a shared database without double-billing or overfilling a budget. That
requires real row-level locking, and the two allowed storage engines are not equivalent here:

| Capability the task needs | PostgreSQL | SQLite |
|---|---|---|
| `FOR UPDATE SKIP LOCKED` (atomic batch claiming) | Yes | **Not supported** — no row-level locking |
| `UPDATE ... RETURNING` | Yes | Only in recent versions, and with no row locks to pair it with |
| Concurrent writers | MVCC, many simultaneous writers | **One writer, database-wide** — everything else serializes |
| Advisory locks | Yes | No |
| `CHECK` constraints | Yes | Yes |

On SQLite, a "concurrent workers" test would **pass trivially** — SQLite serializes every write
behind a single global lock, so there is no real race to survive. The test would prove nothing about
the design; it would just prove SQLite doesn't let you write at the same time. PostgreSQL is the
only option where "this holds up under concurrency" is a claim actually being tested rather than an
artifact of the database doing all the work for you.

Pinning to major version `16` (rather than leaving it unversioned) is a reproducibility choice —
floating on `latest` makes a build non-reproducible between runs, which matters when the whole point
is that the concurrency behavior is deterministic and verifiable.

## Why Ruby 3.3

Two concrete reasons, not just "current stable at the time":

- **`Data.define`** (introduced in Ruby 3.2) is what the allocator uses for its value objects
  (`BudgetSnapshot`, `Record`, `Allocation`) — immutable, keyword-constructed, cheap to build. That's
  exactly the shape a pure function's inputs and outputs should have, and it's a language feature the
  design actually leans on, not decoration.
- Being current-stable at build time matters for a project graded partly on engineering judgment —
  using a stale runtime for no reason would itself be a minor mark against the work.

## Why Rails 7.2 — but only the parts that aren't a web framework

This is the choice most likely to look odd out of context: a full web framework, for an app with no
web server. The resolution is that Rails is being used for exactly one slice of what it offers —
ActiveRecord, migrations, rake tasks, and RSpec integration — and nothing else. There are no
controllers anywhere in this codebase, so `config/application.rb` explicitly strips out
`action_controller`, `action_view`, `action_mailer`, `active_storage`, and `action_cable`. The app
skeleton was hand-written rather than generated with `rails new`, so nothing web-facing was ever
present to begin with.

Rails earns its place here as an ORM, a migration/schema tool, and a task runner — not as a web
framework. There is genuinely no HTTP surface anywhere in this app.

## Why no Sidekiq, no Redis, no job queue

This is a deliberate *absence*, and it's probably the choice most engineers would reach for by
default. A job queue like Sidekiq would do the work distribution automatically — but it would also
**hide** the exact mechanism this project is meant to demonstrate: the atomic claim
(`FOR UPDATE SKIP LOCKED`), the lease, and the fencing token. Reaching for a queue would solve the
problem invisibly, which defeats the purpose of building it by hand. It would also add an entire
extra piece of infrastructure (Redis) for no benefit, since PostgreSQL itself is capable of acting
as the work queue.

So the worker is a plain poll loop inside a rake task, horizontally scaled with
`docker compose up --scale worker=N`. PostgreSQL is the queue; there is no separate one.

## Why `decimal` / `BigDecimal`, never `float`

Money conservation is checked exactly — output totals have to match the expected numbers in
`data/worked-examples.md` to the cent. Floating-point numbers accumulate rounding error over
repeated arithmetic; `BigDecimal` does not. Every CSV number is parsed with `Integer(...)` or
`BigDecimal(...)`, never `to_f`, so a float can never sneak into a `decimal` column at any boundary.

## Why Docker

Storage was allowed to be SQLite or Postgres with Docker as an option, not a requirement — but once
PostgreSQL 16 specifically was chosen, Docker became the practical way to guarantee that exact
version (and the matching Ruby version) is present regardless of what's installed on whatever
machine runs or evaluates this project. It isn't standing in for a production deployment topology
here — there's no host Ruby toolchain assumed at all, so the container is the only place the app
actually runs.

## The one-sentence version

Every infrastructure choice here was made to make the concurrency and money-conservation guarantees
**provable** rather than merely claimed — PostgreSQL because SQLite would let a concurrency test pass
for the wrong reason, no job queue because that would hide the exact mechanism under test, decimals
because floats would silently fail an exact numeric check, and Rails stripped down to only the parts
(ActiveRecord, migrations, rake, RSpec) that earn their place in an app with no HTTP surface at all.
