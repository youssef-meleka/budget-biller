# Business Challenges

What this system is actually protecting, why each requirement in the
[brief](../candidate-brief.md) exists as a commercial problem before it is a technical one, and how
the pipeline answers it.

Every claim here is evidenced by a real end-to-end run, captured in
[Test Run/README.md](Test%20Run/README.md) and [Test Run/run-timeline.md](Test%20Run/run-timeline.md).
Where a number appears below, it came out of that run.

---

## The business in one paragraph

Advertisers give us a budget and a rate. Their ads generate engagements. Every day, a file arrives
telling us how many engagements happened, for which merchant, on which channel — and we convert that
into money charged against their budget. Two things make this harder than multiplying two numbers:
**the budget is a contractual ceiling we are not allowed to exceed**, and **the file is not the
final word** — it can arrive twice, arrive late, or be restated a day later.

Everything below follows from those two facts.

---

## What failure costs

| If this goes wrong | The commercial consequence |
|---|---|
| We bill an engagement twice | We charge an advertiser for traffic they did not agree to buy. Refund, dispute, and a credibility problem that outlives the refund |
| We lose an engagement | Revenue we earned and never invoiced. Invisible, because nothing errors — it simply isn't there |
| We exceed a budget's quota | We billed past the contractual ceiling. Either we absorb the overage or we defend it to the advertiser. At scale, small overfills across many accounts are real money |
| Our numbers disagree with the advertiser's | Every disagreement becomes a manual reconciliation. People-time, not machine-time, and it recurs monthly |
| A correction can't be applied | The advertiser is billed a number both sides know is wrong, or someone fixes it by hand in a spreadsheet outside the system of record |
| Billing stalls when a machine dies | Revenue sits unbilled until a human notices. Close-of-day slips |
| Billing can't keep up with growth | The nightly run finishes later every month until it misses its window |

The pipeline is built so that each of these is prevented by the *structure* of the system, not by
anyone remembering to be careful.

---

## Challenge 1 — The file is not trustworthy about delivery

**The business problem.** Upstream systems retry. Operations teams re-run backfills. A file that was
already processed gets delivered a second time, and nobody upstream considers this an error — because
for them, it isn't. But if our billing treats the second delivery as new traffic, we double-charge an
advertiser because of an operational accident rather than a bug.

**What we do.** Loading a file is defined as *stating what is true for that merchant-day-channel*,
not as *adding rows*. A second delivery of the same file overwrites the same facts with identical
values, so the result is indistinguishable from having loaded it once. There is no counter to get out
of step and no "have I seen this file?" bookkeeping to go stale.

**Proof from the run.** Three file loads — two distinct files plus a deliberate re-delivery of the
first — produced **5 staging rows, not 8**, and every merchant-day fingerprint was byte-identical
before and after the repeat ([Test Run, Phase 4](Test%20Run/README.md)).

**Why this framing matters commercially.** Because the safety comes from what a load *means* rather
than from detecting duplicates, it also holds for cases nobody planned for: a partial re-delivery, an
overlapping file, a file replayed weeks later. There is no list of anticipated failure modes to keep
current.

---

## Challenge 2 — The budget is a ceiling we are contractually not allowed to cross

**The business problem.** `quota` is what the advertiser agreed to spend. Going over it is not a
rounding inconvenience — it is billing for something outside the agreement. And the dangerous version
is not a large overage caught in review; it is a fraction of a cent, on thousands of accounts, that
nobody notices for a quarter.

**What we do — three layers, deliberately.**

1. **The database itself refuses to record an overfill.** The ceiling is a constraint on the data, not
   a check in the application. A future release with a bug in the billing logic cannot write an
   overspend — the write is rejected outright.
2. **Charges are applied as a single indivisible instruction** — "increase the spend by this amount,
   and only if the result stays within the ceiling." The decision and the write cannot be separated by
   another worker slipping in between them.
3. **When only part of a record fits, we always round the quantity *down*.** We bill the largest whole
   number of engagements that fits inside the remaining budget, never the nearest. Rounding to the
   nearest could produce a charge a fraction of a cent above the ceiling — mathematically tiny,
   contractually a breach, and intermittent enough to be very hard to trace.

**Proof from the run.** Two budgets landed at **exactly** their ceiling — 50.00 of 50.00 and 20.00 of
20.00 ([Test Run, Phase 6](Test%20Run/README.md)). Sitting precisely on the limit is the case that
exposes an off-by-a-fraction error; comfortably under it proves nothing. The concurrency test pushes
this harder still: it drives **80 engagements at 35 units of capacity** — deliberately far
oversubscribed — and still lands exactly on the limit, with no overspend.

---

## Challenge 3 — When a budget runs out, the traffic must not disappear

**The business problem.** An advertiser's primary budget filling up mid-day is normal and expected.
What happens next is commercial policy, not an error path: engagements that no longer fit spill to a
secondary budget, charged at *that* budget's rate. And when nothing can absorb them, the business
still needs to know they happened.

**What we do.** Each record is offered to the merchant's primary budget first; whatever fits is
charged there, and the remainder moves to the fallback budget at the fallback's own rate. If the chain
is exhausted, the leftover engagements are recorded in an **unbilled bucket** — a row that carries the
engagements at zero charge.

**Proof from the run.** On 2026-08-20, merchant 100's `web` record split across two budgets — 100
engagements to the primary at 10.00, the remaining 100 to the fallback at 8.00. After the correction
the same record split 150 / 50 instead, because the primary had more room. Both splits are in
[billed_stats.csv](Test%20Run/billed_stats.csv).

**The commercially interesting part.** The unbilled bucket is usually described as an accounting
device to stop numbers going missing. It is more useful than that: **it is a revenue-gap report.** It
says precisely how much demand an advertiser's budget failed to capture, by day and by channel. That
is a renewal and upsell conversation backed by a number, produced as a side effect of billing
correctly. A system that simply dropped unbillable engagements would be arithmetically fine and would
throw that signal away.

---

## Challenge 4 — Two different products are measured on the same traffic

**The business problem.** `engagements` and `premium_engagements` are two commercial metrics counted
over the same events. They are not a total and a subset to be reconciled — they are two ledgers, and
each has to be right on its own. Getting the money right while the premium numbers drift still means
the reporting an advertiser sees is wrong.

**What we do.** The two are tracked and validated **independently**, never derived from one another.
When premium activity exceeds what could be billed to a real budget, the excess is recorded as its
own entry carrying *zero* engagements — so it settles the premium ledger without touching the money
ledger.

**Proof from the run.** For 2026-08-20: engagements balanced at 1050 in / 1050 out, and premium
balanced at 700 in / 700 out — **separately**. The correction moved the engagement ledger from 1100 to
1050 on both sides simultaneously while the premium ledger stayed at 700, untouched, because the
correction did not touch premium ([Test Run, Phase 9](Test%20Run/README.md)).

**A trap in the source data worth naming.** Merchant 200's record carries 500 engagements and 600
premium engagements at a rate of 0.05. The correct charge is on the 500 — **25.00**. Charging the
premium figure instead gives 30.00, which happens to be *exactly* that budget's quota. A wrong
implementation would produce a perfectly plausible-looking number that fills the budget to the brim
and trips no alarm. We charge on engagements, and the premium figure drives reporting only.

---

## Challenge 5 — The data is not final; corrections arrive after we have billed

**The business problem.** Engagement measurement gets restated — bot filtering, late attribution,
partner corrections. A day we billed on Tuesday can be corrected on Wednesday. If billing cannot be
restated safely, the options are to bill a number both sides know is wrong, or to correct it manually
outside the system of record. The second is worse: it is unauditable, and it is where the largest
billing errors in this industry actually come from.

**What we do.** We keep a fingerprint of what we billed for each merchant-day. When a corrected file
changes that day's data, the fingerprint stops matching and **the day re-opens by itself**. The system
then reverses the earlier charges and applies the new ones **as one indivisible step**, so there is no
moment where the budget appears free and a concurrent worker could spend it twice.

Critically, the correction is scoped to the merchant-days whose data actually changed — not to the
whole file, and not to the whole date.

**Proof from the run.** The corrected file was loaded at `16:58:33.760`. Nobody triggered anything.
At `16:58:34.269` — **half a second later, on the workers' own schedule** — the affected merchant-day
was picked up, and **46 milliseconds** later it was fully reversed and re-billed. The advertiser's
secondary budget went from 20.00 back down to 16.00: money genuinely returned, not just recorded
differently. The *other* merchant on that same date was never touched, because its data had not
changed ([Test Run, Phase 8](Test%20Run/README.md) and
[run-timeline, moment 3](Test%20Run/run-timeline.md)).

And the rows from the superseded run are **gone**, not superseded-in-place: the earlier run's
identifier appears nowhere in the final output.

**Why this design choice is the commercially important one.** There is no "reconciliation mode," no
correction command, and no separate process to schedule and monitor. Correcting a day is the *same
operation* as loading it the first time. That means the correction path cannot rot from disuse —
it is exercised every single time anyone loads a file.

---

## Challenge 6 — Growth has to come from adding machines

**The business problem.** Billing volume grows with the advertiser base. If billing is effectively
single-threaded, the nightly close finishes later every month until it misses its window — and the
only fix at that point is a rewrite, under time pressure, in the money path.

**What we do.** Work is divided into independent units of *one merchant, one day*. A worker takes a
unit in a single indivisible action, so two workers can never end up holding the same one. Just as
importantly, a worker that finds a unit already taken **skips past it to the next available one**
rather than queuing behind it — which is the difference between adding capacity and merely adding
spectators.

**Proof from the run.** Two workers claimed **different** units 12 milliseconds apart; all four units
were billed in **660 milliseconds** across three replicas; and every unit shows exactly one claim
attempt, meaning nothing was taken twice and nothing had to be retried ([run-timeline, moment
1](Test%20Run/run-timeline.md)).

**The honest limit.** Two workers billing different days *for the same advertiser* still have to take
turns on that advertiser's budget — that is unavoidable, because they are spending the same finite
pot. Parallelism is therefore across advertisers, not within one. At realistic volumes that is the
right trade: advertisers are many, days per advertiser are few.

---

## Challenge 7 — Machines die, and revenue must not die with them

**The business problem.** A worker that crashes while billing a day must not leave that day frozen
until someone notices. Manual intervention in a money path is slow, and every manual intervention is
an opportunity to make things worse.

**What we do.** Taking a unit of work is a **time-limited claim**, not a permanent one. If a worker
goes silent past its window, the work becomes available to its peers automatically — no monitoring
process, no operator, no cleanup job that itself needs monitoring.

The subtler danger is the worker that does not die but *stalls* — paused long enough that its work was
reassigned, then resumes and tries to finish. We reject that work **before** it is committed, so it is
discarded rather than applied on top of someone else's. A stalled machine cannot double-charge an
advertiser by waking up.

We also cap how many times a single unit may be retried. A genuinely unprocessable day stops consuming
capacity and surfaces as a visible imbalance, rather than retrying silently forever or disappearing
quietly. **Loud beats tidy** when the subject is money.

**One detail worth calling out.** Every deadline is measured by the database's clock, never by the
individual machine's. Replicas drift apart, and nothing synchronises them. If each machine judged its
own deadline, two of them would eventually disagree about who legitimately holds a piece of work — and
that disagreement is precisely a double-billing.

**Proof from the run.** Recovery and stall-rejection each have a dedicated test
([Test Run, Phase 11](Test%20Run/README.md)). In practice it rarely comes to that: on shutdown, all
three replicas finished cleanly and said so within ~2.1 seconds, so a routine deploy strands no work
at all ([run-timeline, moment 4](Test%20Run/run-timeline.md)).

---

## Challenge 8 — Nobody should be able to run billing by hand

**The business problem.** "Someone ran it twice" is one of the most common causes of duplicate
charges in batch billing, and it is an operational failure rather than a coding one. Any system with a
manual *charge the customers* button will eventually have that button pressed twice.

**What we do.** There is no trigger. Workers run continuously and look for work on their own. Work
becomes available because *data changed*, never because a person acted.

The safety here is structural rather than defensive: an already-settled merchant-day is **never
offered to a worker in the first place**. It is not handed out and then rejected — it is not in the
queue at all. There is no window in which the wrong thing is briefly possible.

**Proof from the run.** Three replicas polled for 15 seconds — roughly nine attempts — and produced
**zero** activity. Every billing timestamp and run identifier was identical, to the microsecond,
before and after ([Test Run, Phase 7](Test%20Run/README.md)).

That the log is *empty* for that period is the point. Nothing was attempted, so nothing had to be
correctly refused.

---

## Challenge 9 — "Why was this advertiser charged this?"

**The business problem.** Finance and account management ask this question about specific numbers, and
"the system computed it" is not an answer. It needs to be answerable months later, by someone who was
not there.

**What we do.** Every billing pass is stamped with its own identifier, and every output row carries the
pass that produced it. When a day is re-billed after a correction, the superseded rows are removed and
the new ones carry a new identifier — so the output always shows *which run each number came from*,
and a stale number cannot masquerade as a current one.

The operational log is an **event stream, not a debug trace**: one line per meaningful state change,
each a self-contained structured record. The entire run — three replicas, four merchant-days, a
correction, a full reversal, and a clean shutdown — produced **sixteen lines**
([run-timeline](Test%20Run/run-timeline.md)).

**Why the restraint matters.** A log that records everything is a log nobody reads. Sixteen auditable
events is something a person can actually check.

---

## Challenge 10 — Proving the numbers, continuously and cheaply

**The business problem.** Correctness that can only be established by reading code is correctness the
business cannot verify. Someone needs to be able to ask "is the ledger sound right now?" and get an
answer in seconds — before an advertiser asks first.

**What we do.** The three conservation rules — engagements balance, premium balances, no budget over
its ceiling — are implemented as an **executable check** that runs on demand, returns a plain verdict,
and fails loudly. The same check runs automatically after every integration test, so the invariants
are enforced during development, not only in production.

**Proof from the run.** Verified green **before** the correction and again **after** it, with the
engagement totals visibly moving from 1100 to 1050 on both sides at once, and the premium totals
visibly not moving at all ([Test Run, Phases 6 and 9](Test%20Run/README.md)).

**The business value.** This converts "we believe the billing is correct" into a question with a
one-line answer, cheap enough to run continuously.

---

## What the business should know before relying on this

Stated plainly, because a limitations list nobody wrote down is a limitations list somebody discovers
during an incident.

| Limitation | What it means commercially |
|---|---|
| **Corrections do not cascade forward.** Correcting Monday can free budget that Tuesday would have used, but Tuesday is not automatically recomputed. | After a correction that *frees* budget, later days may be billed more conservatively than the corrected data would now justify. All balance checks still pass — this would not be flagged automatically. |
| **When two days for the same advertiser are billed simultaneously, which one reaches the budget first is not guaranteed.** | The totals are always correct and no ceiling is ever breached, but the *split between those two days* could differ between two otherwise identical runs. Reporting by day could differ; money never goes missing. |
| **A crash midway through loading a file can leave a correction stranded.** | The balance check detects it immediately and loudly, but nothing re-opens the day on its own — it needs a re-load. Detected, not self-healing. |
| **Re-running the initial budget setup after billing has started resets recorded spend to zero.** | Correct under documented use (run once, before billing), but it is a live footgun on a production database and should refuse to run rather than rely on discipline. |
| **A day has no time zone.** | Fine while everyone shares a calendar. The moment advertisers span time zones, "which day is this engagement in?" becomes a real commercial question this model does not yet ask. |

The first two are the ones worth understanding, because **they are invisible to every check the system
performs** — all three conservation rules are evaluated per day, so a day that is internally consistent
but stale, or split differently than a rerun would split it, passes cleanly. They are limitations of
the design, not defects in the implementation, and both have known remedies at a known cost in
parallelism.

---

## Where each requirement is answered

| Brief rule | Business challenge | Demonstrated in |
|---|---|---|
| 1 — Charge, ceiling respected | Contractual spend ceiling (#2) | [Test Run, Phases 5–6](Test%20Run/README.md) |
| 2 — Fallback, unbilled bucket | Don't drop demand; measure the gap (#3) | [Test Run, Phase 5](Test%20Run/README.md), [billed_stats.csv](Test%20Run/billed_stats.csv) |
| 3 — Ingest idempotency | Untrusted delivery (#1) | [Test Run, Phase 4](Test%20Run/README.md) |
| 4 — Billing idempotency, no trigger | No human in the money path (#8) | [Test Run, Phase 7](Test%20Run/README.md) |
| 5 — Atomic claim | Scale by adding machines (#6) | [run-timeline, moment 1](Test%20Run/run-timeline.md) |
| 6 — Atomic fill | Contractual spend ceiling (#2) | [Test Run, Phase 6](Test%20Run/README.md) |
| 7 — Crash recovery | Machines die (#7) | [Test Run, Phase 11](Test%20Run/README.md) |
| 8 — Prove it under concurrency | Scale safely (#6, #7) | [Test Run, Phase 11](Test%20Run/README.md) |
| 9 — Overage split | Two commercial ledgers (#4) | [billed_stats.csv](Test%20Run/billed_stats.csv), row 4 |
| 10 — Reconciliation | Data is restated (#5) | [Test Run, Phase 8](Test%20Run/README.md), [run-timeline, moment 3](Test%20Run/run-timeline.md) |
| Conservation invariants | Provable correctness (#10) | [Test Run, Phases 6 and 9](Test%20Run/README.md) |

---

## The one-sentence version

The system treats **loading data as stating a fact**, **billing as a consequence of data changing**,
and **the budget ceiling as a property of the database rather than a rule the code is trusted to
follow** — which is what allows it to run unattended, on as many machines as needed, and to accept a
correction to yesterday's money without a human touching anything.

## Related reading

- [Test Run/README.md](Test%20Run/README.md) — the full run, step by step, with real output at each stage
- [Test Run/run-timeline.md](Test%20Run/run-timeline.md) — the timestamped event log and four moments worth reading closely
- [Test Run/billed_stats.csv](Test%20Run/billed_stats.csv) — the billing output for all three provided files
- [../README.md](../README.md) — the engineering rationale: mechanisms, trade-offs, and decisions
- [infrastructure/03-concepts-implemented.md](infrastructure/03-concepts-implemented.md) — each concept above, mapped to the code that implements it
