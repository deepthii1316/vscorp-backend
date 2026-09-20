# Virata Retail - Backend (Data Pipeline and Database)

Turns the Excel exports uploaded in the web app into clean tables for the Uppal Reebok reports and dashboard.
It is a **Supabase** database (Postgres + Storage) plus a **Python worker** that runs on GitHub Actions.
The web app is in the separate **frontend** repository.

## How data flows

```
Excel upload (web app) --> Supabase Storage (retail-ops bucket) + upload_audit_log
         |
Process button --> GitHub Actions: run-pipeline.yml
         |
   Stage 1  raw.sales / raw.account_dsr / raw.inventory     files loaded as-is (text)
   Stage 2  staging dimensions (store, product, salesperson, promotion)
   Stage 3  staging.fact_stock
   Stage 4  gold tables                                     the only tables the app reads
```

The gold tables are rebuilt from **all** raw rows on every run, so a run can be repeated safely and file order does not matter.

## Repository layout

```
database/
  schema.sql                 Full schema: raw, staging and gold tables
  migrations/                Changes after the first schema, applied in filename order
worker/pipeline/
  run_pipeline.py            Entry point used by GitHub Actions
  ingest_file.py             Excel loaders (sales, Account DSR, inventory)
  scripts/
    run_pipeline.py          Runs the stages and reports progress
    build_dimensions.py      Staging dimensions
    refresh_stock.py         Stock facts
    refresh_reebok.py        Reebok gold tables (see below)
    refresh_gold.py          Older gold tables (no longer read by the app)
    sales_snapshot.py        Picks the right rows when sales files overlap
    populate_holidays.py     Holiday calendar
    cleanup_storage.py       Maintenance: empty upload folders (lists first, deletes only with --execute)
.github/workflows/run-pipeline.yml   Manual workflow, started by the app
docs/                        Rules and KPI definitions
```

## Gold tables the app reads

| Table | Rows | Used by |
|---|---|---|
| `gold.reebok_daily_metrics` | per day: today, MTD, YTD | Sales Reports and Excel (through `rpt_reebok_*` functions) |
| `gold.reebok_master_dashboard` | per day | Master Dashboard sales figures |
| `gold.reebok_master_dashboard_payments` | per day | Master Dashboard payment modes (from the Account DSR) |

All three are built by `worker/pipeline/scripts/refresh_reebok.py`.

## Data rules built into the pipeline

- **NSV** is the sum of *Taxable Amount*; MRP is stored so MD % = (MRP - NSV) / MRP.
- **Carry bags** (free packaging, class "Carry Bag") are not counted as units sold.
- **Blank Item Division** is resolved from the product class using `CLASS_TO_DIVISION` in `refresh_reebok.py`.
  If a run prints a warning about an unmapped class, add it there and re-run.
- **Footer lines** of the SAP exports ("Bill Value :", "Grand Total:") are skipped by the loaders.
- **Account DSR:** the real Reebok headers are matched exactly. If the same date is in several files, the file whose main month is that date's month wins; later uploads win among equals. Future dates are ignored.
- **Duplicate files** are refused by the app (SHA-256 hash in `upload_audit_log`).

Full KPI definitions: `docs/REEBOOK_KPI_DEFINITIONS.md` (keep it identical to the copy in the frontend repo, `public/REEBOOK_KPI_DEFINITIONS.md`).

## Setup

Prerequisites: Python 3.12+, a Supabase project.

1. **Database:** in the Supabase SQL editor run `database/schema.sql`, then every file in `database/migrations/` in filename order.
2. **Storage:** create a private bucket named `retail-ops`.
3. **Local worker:**
   ```powershell
   cd worker\pipeline
   python -m venv .venv
   .\.venv\Scripts\Activate.ps1
   pip install -r requirements.txt
   Copy-Item .env.example .env        # then fill in the values
   ```
4. **GitHub:** add these repository secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_DB_URL`, `SUPABASE_DB_URL_POOLER`.

## Environment variables (`worker/pipeline/.env`)

| Variable | Meaning |
|---|---|
| `SUPABASE_URL`, `SUPABASE_KEY` | Project URL and service-role key (used for file downloads) |
| `SUPABASE_DB_URL`, `SUPABASE_DB_URL_POOLER` | Postgres connection strings (the pooler one is preferred) |
| `NEXT_PUBLIC_SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | Only needed by `cleanup_storage.py` |

Never commit `.env`; it is git-ignored.

## Running things

| Task | Command (from `worker/pipeline`) |
|---|---|
| Normal processing | Press **Process** in the web app. It starts the GitHub workflow. |
| Rebuild the Reebok tables from existing raw data | `.\.venv\Scripts\python.exe scripts\refresh_reebok.py` |
| See what a storage cleanup would delete | `.\.venv\Scripts\python.exe scripts\cleanup_storage.py` (add `--target inventory` for inventory; `--execute` to delete) |

## Troubleshooting

- **Run stuck or failed:** look at the run in GitHub Actions and at `public.processing_runs` (`status`, `stage`, `error_message`). Only one run works at a time.
- **"certificate verify failed" in Python scripts:** antivirus HTTPS scanning. Run `pip install truststore` in the venv once.
- **Payment split empty:** the Account DSR must be uploaded for those dates, and its columns must match the expected headers.
- **A number looks wrong:** compare `raw.*` rows with the gold table for that date, then check the rules above.

## Known limitations

- `refresh_gold.py` still runs and fills older tables that nothing reads. It can be removed later.
- There are no automated tests yet.
- `docs/CLAUDE.md` is older working notes and may not match the current flow.
