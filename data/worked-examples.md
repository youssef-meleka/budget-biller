# Worked Examples

Process order: `stats_2026-08-20.csv`, then `stats_2026-08-21.csv`, then (Tier 3 only)
`stats_2026-08-20_v2.csv` — its ingest re-opens the affected batches, and the next
scheduled billing run picks them up (Tier 3 only).

Budgets at start: B1 (merchant 100, CPC, rate 0.10, quota 50.00, fallback B2),
B2 (merchant 100, CPC, rate 0.08, quota 20.00), B3 (merchant 200, UEV, rate 0.05, quota 30.00).

## File 1: stats_2026-08-20.csv

**Row 1** — `100,app,400,100`
Charge = 400 × 0.10 = 40.00. B1 fill: 0 → 40.00.
Billed: `(B1, app, 400 eng, 40.00)`.

**Row 2** — `100,web,200,0`
B1 remaining = 10.00 → absorbs 100 eng (10.00). B1 fill: 50.00 (exactly full).
Remainder 100 eng → fallback B2 at 0.08 = 8.00. B2 fill: 8.00.
Billed: `(B1, web, 100, 10.00)` + `(B2, web, 100, 8.00)`.

**Row 3** — `200,app,500,600`
Charge = 500 × 0.05 = 25.00. B3 fill: 25.00. Billed: `(B3, app, 500, 25.00)`.
Tier 3: premium 600 > 500 billed → split: new unbilled-bucket row `(budget 0, app, 100 premium eng, 0.00)`.
Tier 1 implementations without the split still must conserve the 500 real engagements.

**Fills after file 1**: B1 = 50.00, B2 = 8.00, B3 = 25.00.

## File 2: stats_2026-08-21.csv

**Row 1** — `100,app,150,0`
B1 is full → fallback B2: 150 × 0.08 = 12.00. B2 fill: 8.00 → 20.00 (exactly full).
Billed: `(B2, app, 150, 12.00)`.

**Row 2** — `200,web,80,0`
Charge = 80 × 0.05 = 4.00. B3 fill: 29.00. Billed: `(B3, web, 80, 4.00)`.

**Fills after file 2**: B1 = 50.00, B2 = 20.00, B3 = 29.00.

## File 3 (Tier 3): stats_2026-08-20_v2.csv, re-ingest re-opens the batches

Correction: row 1 engagements drop from 400 to 350. Expected behavior:
reverse the old 2026-08-20 billed rows (B1 −50.00 → 0, B2 −8.00 → 12.00,
B3 −25.00 → 4.00), then re-bill:

- Row 1: 350 × 0.10 = 35.00 → B1 fill 35.00.
- Row 2: B1 absorbs 150 eng (15.00, full at 50.00); remainder 50 eng → B2: 4.00 → fill 16.00.
- Row 3: unchanged → B3: 29.00. Sentinel row: 100 premium eng.

**Final fills**: B1 = 50.00, B2 = 16.00, B3 = 29.00.
No 2026-08-20 rows from the first run may remain in `billed_stats`.

## Conservation check (all tiers)

The `engagements` and `premium_engagements` columns are separate ledgers. For each date,
each column must balance on its own: the total across all `billed_stats` rows (real
budgets plus the unbilled bucket) must equal that column's total in the input file.

Example, date 2026-08-20 (file 1):
- Input engagements: 400 + 200 + 500 = **1100**. Output: 400 (B1) + 100 (B1) + 100 (B2)
  + 500 (B3) = **1100**. Balanced.
- Input premium: 100 + 0 + 600 = **700**. Output (Tier 3): 100 (B1) + 500 (B3) +
  100 (unbilled bucket) = **700**. Balanced. Note: a premium-overage row carries
  `engagements = 0`, so it never disturbs the first ledger.

And every budget: `fill ≤ quota`, at all times.
