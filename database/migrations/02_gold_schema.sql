-- =============================================================
-- Migration 02 — Move Master Dashboard tables to dedicated gold schema
-- =============================================================
-- Run once in the Supabase SQL Editor. Safe to re-run.
--
-- Strategy (handles both fresh installs and existing staging tables):
--   1. Create gold schema + grants
--   2. Try to move staging.fact_gold_* tables into gold (IF EXISTS — silent no-op if absent)
--   3. Try to rename fact_gold_* → fact_master_* inside gold (IF EXISTS — silent no-op)
--   4. CREATE TABLE IF NOT EXISTS for each gold table  ← guarantees tables exist
--      regardless of whether step 2/3 ran or not
--   5. Create indexes
-- =============================================================

-- ── Step 1: Create gold schema ────────────────────────────────
CREATE SCHEMA IF NOT EXISTS gold;

-- ── Step 2: Grants ────────────────────────────────────────────
GRANT USAGE ON SCHEMA gold TO postgres, anon, authenticated, service_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA gold TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA gold GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role;

-- ── Step 3: Move from staging → gold (no-op if tables absent) ─
ALTER TABLE IF EXISTS staging.fact_gold_master_dashboard
    SET SCHEMA gold;

ALTER TABLE IF EXISTS staging.fact_gold_master_dashboard_granular
    SET SCHEMA gold;

ALTER TABLE IF EXISTS staging.fact_gold_master_dashboard_payments
    SET SCHEMA gold;

-- ── Step 4: Rename to drop the now-redundant "gold_" prefix ───
-- (no-op if the table name was already correct / didn't exist)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'gold' AND table_name = 'fact_gold_master_dashboard'
    ) THEN
        ALTER TABLE gold.fact_gold_master_dashboard RENAME TO fact_master_dashboard;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'gold' AND table_name = 'fact_gold_master_dashboard_granular'
    ) THEN
        ALTER TABLE gold.fact_gold_master_dashboard_granular RENAME TO fact_master_dashboard_granular;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'gold' AND table_name = 'fact_gold_master_dashboard_payments'
    ) THEN
        ALTER TABLE gold.fact_gold_master_dashboard_payments RENAME TO fact_master_dashboard_payments;
    END IF;
END $$;

-- ── Step 5: CREATE TABLE IF NOT EXISTS (guarantees tables exist) ─
-- If the tables were just moved+renamed above, these are no-ops.
-- If this is a fresh install with no staging tables, they are created now.

CREATE TABLE IF NOT EXISTS gold.fact_master_dashboard (
    full_date          date,
    date_key           integer,
    store_key          integer,
    store_name         text,
    site_short_name    text,
    state              text,
    region             text,
    quantity           numeric DEFAULT 0,
    selling_amount     numeric DEFAULT 0,
    mrp_value          numeric DEFAULT 0,
    bills              integer DEFAULT 0,
    footwear_qty       numeric DEFAULT 0,
    footwear_value     numeric DEFAULT 0,
    apparel_qty        numeric DEFAULT 0,
    apparel_value      numeric DEFAULT 0,
    accessories_qty    numeric DEFAULT 0,
    accessories_value  numeric DEFAULT 0,
    socks_qty          numeric DEFAULT 0,
    socks_value        numeric DEFAULT 0,
    shoes_qty          numeric DEFAULT 0,
    shoes_value        numeric DEFAULT 0,
    loaded_at          timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS gold.fact_master_dashboard_granular (
    full_date          date,
    date_key           integer,
    store_key          integer,
    store_name         text,
    site_short_name    text,
    division           text,
    section            text,
    department         text,
    quantity           numeric DEFAULT 0,
    mrp_value          numeric DEFAULT 0,
    selling_amount     numeric DEFAULT 0,
    loaded_at          timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS gold.fact_master_dashboard_payments (
    full_date          date,
    date_key           integer,
    store_key          integer,
    store_name         text,
    site_short_name    text,
    total_sales        numeric DEFAULT 0,
    total_bills        integer DEFAULT 0,
    upi_amount         numeric DEFAULT 0,
    upi_bills          integer DEFAULT 0,
    cash_amount        numeric DEFAULT 0,
    cash_bills         integer DEFAULT 0,
    card_amount        numeric DEFAULT 0,
    card_bills         integer DEFAULT 0,
    other_amount       numeric DEFAULT 0,
    other_bills        integer DEFAULT 0,
    loaded_at          timestamptz DEFAULT now()
);

-- ── Step 6: Indexes ───────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_gold_master_date
    ON gold.fact_master_dashboard (full_date);

CREATE INDEX IF NOT EXISTS idx_gold_master_store
    ON gold.fact_master_dashboard (store_key);

CREATE INDEX IF NOT EXISTS idx_gold_gran_date
    ON gold.fact_master_dashboard_granular (full_date);

CREATE INDEX IF NOT EXISTS idx_gold_gran_store
    ON gold.fact_master_dashboard_granular (store_key);

CREATE INDEX IF NOT EXISTS idx_gold_gran_div
    ON gold.fact_master_dashboard_granular (division);

CREATE INDEX IF NOT EXISTS idx_gold_pay_date
    ON gold.fact_master_dashboard_payments (full_date);

CREATE INDEX IF NOT EXISTS idx_gold_pay_store
    ON gold.fact_master_dashboard_payments (store_key);

-- ── Verify ────────────────────────────────────────────────────
-- Run this to confirm all three tables exist in gold:
-- SELECT table_schema, table_name
-- FROM information_schema.tables
-- WHERE table_schema = 'gold'
-- ORDER BY table_name;
