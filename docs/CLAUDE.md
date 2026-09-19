# Reebok Sales Ingestion Pipeline (Virata Retail)

## What this repo does
Ingests SAP sales report exports (.xlsx) into a Supabase `raw` schema table,
via a GitHub Actions workflow triggered on push to `data/`. This is the raw
landing zone only — no cleaning, reformatting, or aggregation happens here
by design. Staging (built separately, later) is where cleaned/aggregated
data will live.

## Key files
- `ingest_file.py` — core ingestion logic
- `.github/workflows/ingest.yml` — GitHub Actions trigger
- `data/` — drop zone for incoming SAP export files

## Hard rules — do not "fix" these without asking first

1. **Bill Date must be reformatted after read_excel.**
   `pd.read_excel(..., dtype=str)` does NOT protect date-formatted cells —
   openpyxl parses them into datetime objects before dtype=str applies.
   We explicitly run `.dt.strftime('%d-%m-%Y')` to restore the source
   format. Removing this reintroduces silent date corruption
   (e.g. `01-07-2026` becomes `2026-07-03 00:00:00`).

2. **Header row is at index 7 (`header=7`).**
   The SAP export has a title block and metadata rows above the real
   header row. This offset is specific to this report's export format —
   verify with `df.tail(10)` / manual inspection if a new file's structure
   looks different before changing this number.

3. **Footer rows are filtered via `df['Store Number'].notna()`.**
   The SAP export includes summary rows at the bottom (Bill Value, Grand
   Total, Round-Off Value, etc.) with no Store Number. This filter removes
   them. Do not remove this filter — footer rows breaking downstream
   aggregation is a real, previously-hit bug.

12. **NSV = SUM(Taxable Amount), not "Value".**
    The SAP export's `Value` column is gross amount. The final/canonical
    amount for Uppal Reebok KPIs is `Taxable Amount` (NSV/RSV).
    `refresh_gold.py` and `refresh_reebok.py` both read `Taxable Amount`.
    Do not "simplify" back to `Value` — that is gross pre-tax.

13. **Gold-layer refresh TRUNCATEs before re-inserting — destructive.**
    `refresh_gold.py` and `refresh_reebok.py` both `TRUNCATE` their
    target gold table before re-inserting. Running them while the
    report pipeline is serving live traffic will serve empty reports
    for the duration of the run. If you need non-destructive
    incremental loads, that is a redesign — do not silently remove
    the TRUNCATE.

4. **NaN → None conversion is required before insert.**
   pandas represents empty cells as NaN (a float) even under dtype=str.
   Supabase's client JSON-encodes records before sending, and `NaN` is not
   valid JSON — this crashes the insert. Values must be converted to
   `None` first (see the NaN-check loop in `ingest_file`).

5. **All raw table columns are `text`, no exceptions.**
   Per the task spec: raw layer preserves the source exactly, no
   reformatting or type inference. This includes SAP CODE, Bill No., and
   date/time columns — never cast these to int/numeric/date types here.

6. **`.schema('raw')` must precede `.table(...)` in every Supabase call.**
   The client defaults to the `public` schema. Supabase also requires
   `raw` to be explicitly added under Project Settings → Data API →
   Exposed schemas, or every insert will fail with "Invalid schema."

7. **All Excel columns must be mapped explicitly to DB columns.**
   Raw database tables (e.g. `raw.sales`) define a subset of target columns.
   Ingestion paths must map source headers (e.g., `SAP CODE`, `Stock No.`)
   to target table names (`SAP Code`, `Bar Code`) to prevent "column does not exist" failures.

8. **Supabase JS client does not support `.table()`.**
   In JavaScript API routes, always use `.from(tableName)` instead of
   `.table(tableName)` (which is only valid in the Python client).

9. **Separate default key=0 inserts in Postgrest batches.**
   When batch-inserting records where one record has an explicit PK key (like `promo_key=0` for `NO_PROMO`) and others auto-generate theirs, Postgrest pads missing keys with `null`, violating NOT NULL constraints. Always split default row inserts from auto-incremented inserts in Python.

10. **STRICTLY REAL/LIVE DATA ONLY — ZERO MOCK FALLBACKS.**
    Never return hardcoded sample/mock lists, sample store lists, or fake numbers anywhere in API routes, python scripts, or UI components. If database tables are empty, return 0 / empty arrays so the UI renders clean zero states.

11. **SINGLE STORE SCOPE (UPPAL - R1157).**
    Reebok operations under Virata Retail are strictly for **1 single store in Uppal (`R1157` / `UPPAL`)**. Never display or insert multi-store mock lists (like SCCM, Karkhana, Vijayawada, etc.).

## Known operational gotchas

- **The GitHub Actions workflow re-processes every `.xlsx` file in `data/`
  on every run** — not just newly added ones. Re-triggering without
  clearing already-ingested files out of `data/` causes duplicate inserts
  (confirmed: this doubled row count from 619 → 1238 during testing).
  Until auto-cleanup is built, remove/archive a file from `data/` after
  a successful run before adding the next one.

- **Watch for `~$`-prefixed files in `data/`.** These are Microsoft Office
  lock/temp files created while the real file is open elsewhere. They are
  not valid Excel files and will crash `pd.read_excel` with
  "Excel file format cannot be determined." Delete them, don't debug them.

- **Do not add `if: secrets.X != ''` conditions to skip steps when
  secrets are missing.** An earlier auto-generated fix did this — it
  causes the workflow to report success (green) while silently doing
  nothing, which is worse than a loud failure. If secrets are missing,
  the job should fail visibly.

- **`sys.argv` filepath can arrive as an empty string** if GitHub's
  `github.event.head_commit.added[0]` doesn't resolve cleanly (multi-commit
  pushes, web-UI uploads, etc.). `resolve_filepath()` handles this by
  falling back to scanning `data/*.xlsx` directly — don't reintroduce a
  hard dependency on `head_commit.added`.

## Open decisions (not yet resolved — do not assume an answer)

- ~~Daily sales report metric definition~~ **RESOLVED 2026-09-05**:
  NSV Achieved = `SUM(Taxable Amount)`, per
  [REEBOOK_KPI_DEFINITIONS.md](./REEBOOK_KPI_DEFINITIONS.md).
  The existing ₹45,161 target stays NULL (do not reverse-engineer);
  the approved ₹8L monthly-budget × week/day split is applied at the
  report layer via `calcTarget` in
  `frontend/src/lib/email/reebokHelpers.js`. If the manager later
  provides a different formula, update REEBOOK_KPI_DEFINITIONS.md
  and the helper together — not the gold table.

- Target formula for the Achievement % cell: the cell is left NULL in
  `gold.reebok_daily_metrics` because the existing ₹45,161 value was
  Claude-generated and the manager said it can change. The approved
  assumption is ₹8,00,000 monthly × week fraction (1st=25%, 2nd=20%,
  3rd=20%, 4th=15%) × day fraction (weekend=50%, weekday=15%),
  applied at the report layer.

## Current state (update the date when this changes)
- As of 2026-09-05:
  - Gold layer active: `gold.reebok_daily_metrics` populated by
    `pipeline/scripts/refresh_reebok.py` for UPPAL (R1157 only).
    One row per (full_date, period_type) for both 'today' and 'mtd'.
  - 4 RPCs deployed via
    `backend/database/migrations/2026_09_05_reebok_rpcs.sql`:
    `rpt_reebok_daywise`, `rpt_reebok_staffwise`,
    `rpt_reebok_category`, `rpt_reebok_gender_division`.
  - In-page report UI is live at `/reebok-reports` (calls
    `/api/reports/reebok-sales`). Excel export at
    `/api/reports/reebok-export`. No email/PNG pipeline yet.
  - Single-store scope confirmed: only R1157 (UPPAL) is processed.
    No other store ids appear in the report pipeline.
  - 3 sales associates seeded into `staging.dim_salesperson` with
    codes REE001/REE002/REE003 (Balraj Gaddam, Rambabu Dharavath,
    Erri Srija).
- As of 2026-08-20:
  - Confirmed continuing on Supabase Free Tier.
  - Database schema contains `raw` and `staging` schemas.
  - The Next.js upload portal and CLI ingestion are operational, mapping raw fields to `raw.sales`.
  - Staging `dim_date` has 1,826 conformed entries and 111 mapped holidays for TS and AP via `holiday_reference`.
  - Table schemas in `schema.sql` and dimension scripts are being aligned with `VS Corp _ Build Instructions _ Database.docx`.

## Maintenance instruction for whichever agent is reading this

Keep this file current as part of the work, not as cleanup afterward.
Specifically:

- If you fix a bug that could plausibly be "fixed" again in the wrong
  direction by a future session (e.g. removing a guardrail that looks
  redundant but isn't), add it to "Hard rules" immediately, in the same
  turn — not as a follow-up.
- If a design decision gets made that wasn't obvious or had real
  alternatives (e.g. how dedup is handled, how a report's grain is
  defined), add it under "Open decisions" if unresolved, or move it to
  a dated entry under "Current state" if resolved.
- If you complete a task or milestone from the project's task doc, update
  "Current state" with the date and what's now true — don't leave stale
  numbers (row counts, table state) sitting there.
- Before making this update, ask the user to confirm the summary is
  accurate rather than silently rewriting the file — a wrong entry here
  is worse than no entry, since future sessions will trust it.
- Keep additions terse — one to three lines per item, instructive
  ("do X" / "don't do Y and here's why"), not narrative.