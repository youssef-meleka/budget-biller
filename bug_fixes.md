# Bug Fixes

Three defects found while preparing to defend this code. All three are silent — none
raises an error a human would see, and two of them make the system report success while
losing money. They are listed worst-first by business impact, not by how hard they are
to fix.

Each entry gives the mechanism, what it costs the business, and the fix applied.

---

## M1 — Two unbilled-bucket rows collide, and the collision is swallowed as success

**Severity: critical. Data loss, silent.**

### The mechanism

`Billing::Allocator` emits its "nothing could absorb this" rows in two independent
blocks: one for engagements that spill past the end of the fallback chain, and one for
premium engagements left over after every real budget took its share. Nothing stopped
both blocks from firing for the same record.

Trace `engagements: 11, premium: 20` against a single budget with capacity for 10 units
and no fallback:

```
(budget 1, eng 10, prem 10)   # what the real budget could afford
(budget 0, eng  1, prem  1)   # engagement spill      → allocator.rb, first tail block
(budget 0, eng  0, prem  9)   # premium overage       → allocator.rb, second tail block
              ^^ both carry the same (date, merchant, channel, budget_id = 0)
```

`assert_conservation!` passes — 11 engagements and 20 premium are all accounted for, the
arithmetic is correct. The failure happens one layer down, at persistence:
`billed_stats` has a unique index on `(date, merchant_id, channel, budget_id)`, so the
second bucket row collides with the first and Postgres raises `RecordNotUnique`.

That exception unwinds the whole transaction, then lands in `BillBatch.call_next`'s
`rescue ActiveRecord::RecordNotUnique` branch — which exists for a completely different,
benign reason: a peer worker having already billed this batch. The rescue cannot tell
the two causes apart. It logs `batch.already_billed` and marks the batch `billed`.

The batch ends up marked billed having written **zero rows** and moved **zero fill**.
Because that path never reaches `fence_commit!`, `billed_digest` stays `NULL`, and
`staging_digest != NULL` evaluates to `NULL` rather than true — so the batch is never
eligible for re-claiming either. The work is gone permanently, and nothing anywhere
raises.

### What it costs the business

A merchant's engagements for an entire `(date, merchant)` batch vanish. Nobody is
billed for delivery that actually happened — direct, unrecoverable revenue loss — and
the `billed_stats` ledger no longer matches what the ad server delivered, so the
discrepancy surfaces later as an unexplained reconciliation gap with no audit trail
pointing at its cause. The batch reports as successfully billed in the logs, so no alert
fires and no on-call engineer is paged. It is discovered, if at all, by someone manually
comparing delivery totals to billing totals weeks later.

It is unreachable on the currently provided data for a coincidence, not a reason: the
only record that spills across a fallback carries zero premium, and the only record with
premium overage does not spill. Any future file containing one row that does both
triggers it.

### The fix

`app/services/billing/allocator.rb` — merge the two tail blocks into one. Whatever the
chain could not absorb, engagements and premium alike, becomes a single bucket row, so
one record can never produce two rows sharing the same key.

### Why the specs missed it

Every allocator example varied one dimension at a time — a spill with no premium, or
premium overage with no spill. None combined them. A regression spec covering both
conditions together has been added.

### The deeper issue this exposes

The `RecordNotUnique` rescue is too broad. It assumes the only possible cause is a peer
having already billed the batch, so a genuine constraint violation — a real bug — is
converted into a success path. Narrowing that rescue (or distinguishing "the row that
collided belongs to another `billing_run_id`" from "it belongs to my own run") is a
follow-up worth doing, and is not part of this change.

---

## M2 — Ingest is not transactional, so a crash loses a correction permanently

**Severity: critical. Silent loss of a correction.**

### The mechanism

`Ingest::LoadFile#call` performed two independent writes with nothing binding them
together:

1. `upsert_pending_engagements` — writes the staged rows.
2. `touch_batches` — recomputes `staging_digest`, which is what advertises those rows as
   changed and re-opens the batch for billing.

Each statement is individually atomic; the *pair* was not. Kill the process between them
— OOM, container restart, deploy, `Ctrl-C` — and staging holds the corrected value (say,
350) while `staging_digest` still hashes the value it replaced (400).

The claim predicate then reads `staging_digest = billed_digest` and concludes the batch
is settled. It is not eligible, no worker will ever pick it up, and no error was raised
at any point. The only thing that fixes it is someone happening to re-run that exact
ingest — and nothing tells anyone to.

### What it costs the business

A correction that was issued, accepted, and half-applied is silently ignored. The
merchant keeps being billed against superseded numbers — either overbilled (money taken
that was disputed and corrected) or underbilled (revenue never collected), depending on
which direction the correction went. Because the batch reads as settled, the conservation
check compares staged data against billed data and finds them consistent — both reflect
the state the system believes is current. The system reports healthy while the invoice is
wrong. This is the failure mode most likely to reach a customer as a disputed invoice
that nobody internally can explain.

### The fix

`app/services/ingest/load_file.rb` — wrap both writes in a single
`ActiveRecord::Base.transaction`. The staged rows and the digest that advertises them are
one fact; they commit together or not at all.

This also closes a second, narrower hole. `staging_digest_for` computes the digest by
*reading back* the table rather than hashing the rows in hand, which was a read-after-write
across a transaction boundary — two concurrent ingests touching the same batch could
interleave upsert and read, and stamp a digest matching neither file. With both statements
inside one transaction, the second ingest's upsert blocks on the first's row locks until
it commits, then reads a consistent picture.

Computing the digest from the rows being written rather than re-reading them would remove
the read-back entirely and is a further improvement; it is not part of this change.

---

## M3 — A failed batch silently switches off the conservation check for its whole date

**Severity: critical. The monitor lies.**

### The mechanism

`Billing::ConservationCheck#compare` built its set of dates to skip from
`where.not(state: "billed")`, intending to mean "work that hasn't finished yet is pending,
not a violation." That is correct for `pending` and `claimed`.

It also matches `failed`. And `failed` is terminal — the claim query's
`WHERE state != 'failed'` guarantees such a batch will never be claimed or billed again.

So a batch that exhausts `MAX_ATTEMPTS` and dies removes its **entire date** from both
I1 and I2 — not just its own rows, but every other merchant's batches on that date too.
`billing:verify` then prints `conservation OK`.

The README claimed a poisoned batch "leaves a loud imbalance rather than vanishing."
It did precisely the opposite: it suppressed the imbalance it caused.

### What it costs the business

This is the worst kind of defect because it disables the detector rather than breaking
the thing being detected. The engagements in a failed batch are genuinely lost — that is
real revenue never billed — and the one mechanism built to catch exactly that condition
is switched off *by* that condition. Worse, it takes the rest of the date's merchants
down with it: a single poisoned batch blinds conservation checking for every other
merchant billed that day, so an unrelated, second problem occurring on the same date also
goes unreported. Every downstream consumer of `billing:verify` — a CI gate, a monitoring
alert, an operator's manual check before closing the books — is told the ledgers balance
when they do not.

### The fix

`app/services/billing/conservation_check.rb`, two changes:

1. **`failed` no longer suppresses a date.** The skip set is now built explicitly from
   `pending` and `claimed` (plus billed batches whose digest has moved and are awaiting
   a re-bill) — genuinely in-flight work only. A failed batch's date is now compared
   normally, so the imbalance it causes is reported as a real I1/I2 violation.
2. **A failed batch raises its own violation.** A new `:abandoned` kind names the batch
   directly, reporting how many engagements were staged against how many were actually
   billed, so an operator sees the cause and not only the symptom.

---

## Files changed

| File | Change |
|---|---|
| `app/services/billing/allocator.rb` | M1 — one bucket allocation per record, never two |
| `app/services/ingest/load_file.rb` | M2 — staged rows and digest commit in one transaction |
| `app/services/billing/conservation_check.rb` | M3 — `failed` reported as `:abandoned`, no longer suppresses its date |
| `spec/services/billing/allocator_spec.rb` | M1 regression — a record that both spills and has premium overage |

