-- =============================================================
-- Reebok Data Upload Portal — Supabase Schema (v2)
-- =============================================================
-- Run this in the Supabase SQL Editor.
-- Prerequisites:
--   1. Create schema 'raw' if it doesn't exist
--   2. Add 'raw' to Project Settings → API → Exposed schemas
-- =============================================================

-- Ensure the raw schema exists
CREATE SCHEMA IF NOT EXISTS raw;

-- =============================================================
-- 1. PUBLIC.UPLOAD_AUDIT_LOG — Dedup & upload history
--    Lives in public schema (not raw). Tracks every upload
--    attempt with SHA-256 hash for duplicate detection.
-- =============================================================
CREATE TABLE IF NOT EXISTS public.upload_audit_log (
    id                  uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    file_sha256         text NOT NULL UNIQUE,
    original_file_name  text NOT NULL,
    renamed_file_name   text NOT NULL,
    report_type         text NOT NULL CHECK (report_type IN ('sales', 'inventory', 'account_dsr')),
    storage_path        text,
    row_count           integer DEFAULT 0,
    file_size_bytes     bigint,
    uploaded_by         text NOT NULL DEFAULT 'admin',
    uploaded_at         timestamptz DEFAULT now(),
    status              text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'uploaded', 'processing', 'success', 'completed', 'failed')),
    error_message       text
);

-- Fast SHA lookups during dedup check
CREATE INDEX IF NOT EXISTS idx_audit_log_sha256
    ON public.upload_audit_log (file_sha256);

-- Recent uploads listing
CREATE INDEX IF NOT EXISTS idx_audit_log_uploaded_at
    ON public.upload_audit_log (uploaded_at DESC);


-- =============================================================
-- 2. RAW.SALES — Bill-Wise Item List
-- =============================================================
-- Columns based on the SAP/Reebok export format.
-- All source columns stored as text — no type casting in raw.
CREATE TABLE IF NOT EXISTS raw.sales (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "Store Number"      text,
    "Store Name"        text,
    "SAP Code"          text,
    "Bar Code"          text,
    "Item Description"  text,
    "Size"              text,
    "MRP"               text,
    "Bill No."          text,
    "Bill Date"         text,
    "Qty"               text,
    "Disc %"            text,
    "Value"             text,
    "CGST"              text,
    "SGST"              text,
    "IGST"              text,
    "Taxable Amount"    text,
    "Brand"             text,
    "Section"           text,
    "Category"          text,
    "Region"            text,
    "State Name"        text,
    "Store GSTIN"       text,
    "Salesman"          text,
    "Sales Promo Code"  text,
    "Sales Promo Description" text,
    "HSN Code"          text,
    "Style Code"        text,
    "Item Division"     text,
    "Class Name"        text,
    "Sub Class"         text,
    -- Inline audit columns
    uploaded_at         text NOT NULL,
    uploaded_by         text NOT NULL,
    source_file_name    text NOT NULL,
    ingestion_method    text NOT NULL DEFAULT 'manual'
);


-- =============================================================
-- 3. RAW.INVENTORY — Stock Item Report
-- =============================================================
-- Column list is a best-guess. Will be refined with sample file.
CREATE TABLE IF NOT EXISTS raw.inventory (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "Store Number"      text,
    "Store Name"        text,
    "SAP Code"          text,
    "Bar Code"          text,
    "Item Description"  text,
    "Size"              text,
    "MRP"               text,
    "Stock Qty"         text,
    "Stock Value"       text,
    "Brand"             text,
    "Section"           text,
    "Category"          text,
    -- Inline audit columns
    uploaded_at         text NOT NULL,
    uploaded_by         text NOT NULL,
    source_file_name    text NOT NULL,
    ingestion_method    text NOT NULL DEFAULT 'manual'
);


-- =============================================================
-- 4. RAW.ACCOUNT_DSR — Payment Mode Split
-- =============================================================
-- Daily sales register with UPI/Cash/Card breakdown.
-- Column list is a best-guess. Will be refined with sample file.
CREATE TABLE IF NOT EXISTS raw.account_dsr (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "Date"              text,
    "Store Number"      text,
    "Store Name"        text,
    "Total Bills"       text,
    "Total Sales"       text,
    "Cash Amount"       text,
    "Cash Bills"        text,
    "Card Amount"       text,
    "Card Bills"        text,
    "UPI Amount"        text,
    "UPI Bills"         text,
    "Other Amount"      text,
    "Other Bills"       text,
    -- Inline audit columns
    uploaded_at         text NOT NULL,
    uploaded_by         text NOT NULL,
    source_file_name    text NOT NULL,
    ingestion_method    text NOT NULL DEFAULT 'manual'
);


-- =============================================================
-- STORAGE BUCKET (create via Supabase Dashboard)
-- =============================================================
-- Bucket name: retail-ops
-- Private bucket (not public)
-- Folder structure (managed by the app):
--
--   retail-ops/
--   ├── archive/          (future use)
--   ├── errors/           (future use)
--   ├── processed/        (future use)
--   └── raw/
--       ├── sales/        → sales_2026_08_08_134500.xlsx
--       ├── inventory/    → inventory_2026_08_08_134500.xlsx
--       └── account-dsr/  → account_dsr_2026_08_08_134500.xlsx


-- =============================================================
-- DATABASE GRANTS & PERMISSIONS (run in SQL Editor)
-- =============================================================
-- Grant usage on raw schema to API roles
GRANT USAGE ON SCHEMA raw TO postgres, anon, authenticated, service_role;

-- Grant privileges on all existing tables in raw schema
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA raw TO postgres, anon, authenticated, service_role;

-- Ensure future tables in raw schema get these privileges automatically
ALTER DEFAULT PRIVILEGES IN SCHEMA raw GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role;


-- =============================================================
-- Reebok Data Upload Portal — Staging Schema (Medallion Silver)
-- =============================================================

-- Ensure the staging schema exists
CREATE SCHEMA IF NOT EXISTS staging;

-- Grant usage on staging schema to API roles
GRANT USAGE ON SCHEMA staging TO postgres, anon, authenticated, service_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA staging TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA staging GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role;

-- =============================================================
-- 1. STAGING.HOLIDAY_REFERENCE
-- =============================================================
-- Stores moving Indian holidays. Populated via Python script.
CREATE TABLE IF NOT EXISTS staging.holiday_reference (
    full_date       date PRIMARY KEY,
    holiday_name    text NOT NULL
);

-- =============================================================
-- 2. STAGING.DIM_DATE (Calendar Dimension)
-- =============================================================
-- Conformed calendar table with April-March Financial Year formatting.
CREATE TABLE IF NOT EXISTS staging.dim_date (
    date_key        integer PRIMARY KEY,
    full_date       date NOT NULL UNIQUE,
    day             integer NOT NULL,
    day_of_week     integer NOT NULL, -- 1 = Monday, 7 = Sunday
    week_of_year    integer NOT NULL,
    month           integer NOT NULL,
    month_name      text NOT NULL,
    quarter         integer NOT NULL,
    year            integer NOT NULL,
    financial_year  text NOT NULL, -- e.g. FY2025-26
    is_weekend      boolean NOT NULL,
    is_holiday      boolean NOT NULL DEFAULT false
);

-- =============================================================
-- 3. CALENDAR GENERATION QUERY
-- =============================================================
-- Generates calendar entries from 2026-01-01 to 2030-12-31.
INSERT INTO staging.dim_date (
    date_key,
    full_date,
    day,
    day_of_week,
    week_of_year,
    month,
    month_name,
    quarter,
    year,
    financial_year,
    is_weekend,
    is_holiday
)
SELECT
    to_char(d, 'YYYYMMDD')::integer as date_key,
    d::date as full_date,
    extract(day from d)::integer as day,
    extract(isodow from d)::integer as day_of_week, -- 1 = Monday, 7 = Sunday
    extract(week from d)::integer as week_of_year,
    extract(month from d)::integer as month,
    trim(to_char(d, 'Month')) as month_name,
    extract(quarter from d)::integer as quarter,
    extract(year from d)::integer as year,
    -- April-March Financial Year logic (India standard)
    CASE 
        WHEN extract(month from d) >= 4 THEN
            'FY' || extract(year from d)::text || '-' || substring((extract(year from d) + 1)::text from 3 for 2)
        ELSE
            'FY' || (extract(year from d) - 1)::text || '-' || substring(extract(year from d)::text from 3 for 2)
    END as financial_year,
    CASE 
        WHEN extract(isodow from d) IN (6, 7) THEN true
        ELSE false
    END as is_weekend,
    false as is_holiday
FROM generate_series('2026-01-01'::date, '2030-12-31'::date, '1 day'::interval) d
ON CONFLICT (date_key) DO NOTHING;
-- =============================================================
-- REBUILD STAGING SCHEMA TABLES (Optional: drops old staging tables)
-- =============================================================
DROP TABLE IF EXISTS staging.fact_stock CASCADE;
DROP TABLE IF EXISTS staging.fact_sales CASCADE;
DROP TABLE IF EXISTS staging.dim_product CASCADE;
DROP TABLE IF EXISTS staging.dim_store CASCADE;
DROP TABLE IF EXISTS staging.dim_salesperson CASCADE;
DROP TABLE IF EXISTS staging.dim_promotion CASCADE;

-- =============================================================
-- 4. STAGING.DIM_PRODUCT
-- =============================================================
CREATE TABLE IF NOT EXISTS staging.dim_product (
    product_key      integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    barcode          text NOT NULL UNIQUE,
    article_name     text,
    short_name       text,
    section          text,
    department       text,
    division         text,
    category_1       text,
    category_2       text,
    category_4       text,
    category_5       text,
    color            text,
    hsn_code         text,
    mrp              numeric,
    vendor_name      text,
    partner_name     text
);

-- =============================================================
-- 5. STAGING.DIM_STORE
-- =============================================================
CREATE TABLE IF NOT EXISTS staging.dim_store (
    store_key              integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    site_name              text,
    site_short_name        text UNIQUE,
    site_code              text,
    city                   text,
    state                  text,
    region                 text,
    asm                    text,
    footfall_location_name text
);

-- =============================================================
-- 6. STAGING.DIM_SALESPERSON
-- =============================================================
CREATE TABLE IF NOT EXISTS staging.dim_salesperson (
    salesperson_key      integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    salesperson_name_raw text,
    salesperson_name     text,
    salesperson_code     text,
    status               text DEFAULT 'Active'
);

-- =============================================================
-- 7. STAGING.DIM_PROMOTION
-- =============================================================
CREATE TABLE IF NOT EXISTS staging.dim_promotion (
    promo_key        integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    promo_code       text NOT NULL UNIQUE,
    promo_description text
);

-- =============================================================
-- 8. STAGING.FACT_SALES
-- =============================================================
CREATE TABLE IF NOT EXISTS staging.fact_sales (
    sales_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    date_key          integer REFERENCES staging.dim_date(date_key),
    product_key       integer REFERENCES staging.dim_product(product_key),
    store_key         integer REFERENCES staging.dim_store(store_key),
    salesperson_key   integer REFERENCES staging.dim_salesperson(salesperson_key),
    bill_no           text,
    bill_datetime     text,
    sales_type        text,
    quantity          numeric,
    sale_mrp          numeric,
    selling_amount    numeric,
    tax_amount        numeric,
    tax_percent       numeric,
    taxable_amount    numeric,
    discount_amount   numeric,
    discount_derived  numeric
);

-- =============================================================
-- 9. STAGING.FACT_STOCK
-- =============================================================
CREATE TABLE IF NOT EXISTS staging.fact_stock (
    stock_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    snapshot_date_key  integer REFERENCES staging.dim_date(date_key),
    product_key        integer REFERENCES staging.dim_product(product_key),
    store_key          integer REFERENCES staging.dim_store(store_key),
    stock_location     text,
    closing_total_qty  numeric,
    last_received_rate numeric,
    last_grn_date_key  integer,
    stock_in_date_key  integer
);

-- =============================================================
-- GOLD SCHEMA — Dashboard Consumption Layer (Exposed to API)
-- =============================================================
-- gold schema is the final, clean output consumed by the API.
-- Tables are refreshed by the upload pipeline after every ingest.
-- =============================================================

CREATE SCHEMA IF NOT EXISTS gold;

-- Grant usage on gold schema to API roles
GRANT USAGE ON SCHEMA gold TO postgres, anon, authenticated, service_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA gold TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA gold GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role;

-- 1. GOLD.FACT_MASTER_DASHBOARD (Store x Day Summary Table)
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
CREATE INDEX IF NOT EXISTS idx_gold_master_date ON gold.fact_master_dashboard (full_date);
CREATE INDEX IF NOT EXISTS idx_gold_master_store ON gold.fact_master_dashboard (store_key);

-- 2. GOLD.FACT_MASTER_DASHBOARD_GRANULAR (Store x Day x Division Table)
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
CREATE INDEX IF NOT EXISTS idx_gold_gran_date ON gold.fact_master_dashboard_granular (full_date);
CREATE INDEX IF NOT EXISTS idx_gold_gran_store ON gold.fact_master_dashboard_granular (store_key);
CREATE INDEX IF NOT EXISTS idx_gold_gran_div ON gold.fact_master_dashboard_granular (division);

-- 3. GOLD.FACT_MASTER_DASHBOARD_PAYMENTS (Account DSR Payment Split Table)
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
CREATE INDEX IF NOT EXISTS idx_gold_pay_date ON gold.fact_master_dashboard_payments (full_date);
CREATE INDEX IF NOT EXISTS idx_gold_pay_store ON gold.fact_master_dashboard_payments (store_key);


-- =============================================================
-- 4. GOLD.REEBOK_DAILY_METRICS (Uppal Reebok — Single Store)
-- =============================================================
-- Pre-aggregated daily + MTD metrics for the Uppal Reebok sales reports.
-- One row per (full_date, period_type) — covers all 4 reports.
--
-- Source: raw.sales where "Store Number" = 'R1157'.
-- Refreshed by pipeline/scripts/refresh_reebok.py after each ingest.
--
-- Hard rules:
--   * NSV/RSV = SUM("Taxable Amount") (never MRP, never Value).
--   * Ratios (SFR/AFR/ATV/UPT/ASP/FUPT) are recalculated at each level
--     from summed numerators/denominators — never averaged.
--   * period_type in ('today','mtd') — one table for both views.
--   * target is NULL unless derived from the approved ₹8L / weekday=15% /
--     weekend=50% rules; if unknown, stay NULL (no reverse-engineering).
--   * division_breakdown and staffwise are JSONB — these dimensions vary
--     by export and we do not want to lock the schema to specific values.
-- =============================================================
CREATE TABLE IF NOT EXISTS gold.reebok_daily_metrics (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_date           date        NOT NULL,
    period_type         text        NOT NULL CHECK (period_type IN ('today', 'mtd')),
    -- Store identity
    store_name          text,
    site_short_name     text        NOT NULL,
    -- Headline metrics
    nsv                 numeric     DEFAULT 0,        -- SUM(Taxable Amount)
    target              numeric,                       -- NULL if not derivable
    achievement_pct     numeric,                       -- (nsv/target)*100, NULL if target NULL
    bills               integer     DEFAULT 0,
    qty_sold            numeric     DEFAULT 0,
    -- Transaction KPIs
    atv                 numeric,                       -- nsv / bills
    upt                 numeric,                       -- qty / bills
    asp                 numeric,                       -- nsv / qty
    fupt                numeric,                       -- footwear_qty / bills
    -- Category quantities + values
    footwear_qty        numeric     DEFAULT 0,
    footwear_nsv        numeric     DEFAULT 0,
    apparel_qty         numeric     DEFAULT 0,
    apparel_nsv         numeric     DEFAULT 0,
    accessories_qty     numeric     DEFAULT 0,
    accessories_nsv     numeric     DEFAULT 0,
    socks_qty           numeric     DEFAULT 0,
    socks_nsv           numeric     DEFAULT 0,
    -- Cross-sell ratios (recalculated from totals — never averaged)
    sfr                 numeric,                       -- socks_qty / footwear_qty
    afr                 numeric,                       -- apparel_qty / footwear_qty
    -- Gender split
    men_qty             numeric     DEFAULT 0,
    women_qty           numeric     DEFAULT 0,
    unisex_qty          numeric     DEFAULT 0,
    men_nsv             numeric     DEFAULT 0,
    women_nsv           numeric     DEFAULT 0,
    unisex_nsv          numeric     DEFAULT 0,
    -- Dynamic breakdowns (divisions vary by export — keep flexible)
    division_breakdown  jsonb       DEFAULT '{}'::jsonb,
    gender_division     jsonb       DEFAULT '{}'::jsonb,
    -- Per-associate breakdown for the 3 sales associates
    staffwise           jsonb       DEFAULT '{}'::jsonb,
    -- Audit
    loaded_at           timestamptz DEFAULT now()
);

-- Unique constraint so refresh_reebok.py can use ON CONFLICT upserts.
CREATE UNIQUE INDEX IF NOT EXISTS idx_reebok_metrics_date_period
    ON gold.reebok_daily_metrics (full_date, period_type);
CREATE INDEX IF NOT EXISTS idx_reebok_metrics_store
    ON gold.reebok_daily_metrics (site_short_name);
CREATE INDEX IF NOT EXISTS idx_reebok_metrics_loaded
    ON gold.reebok_daily_metrics (loaded_at DESC);


-- =============================================================
-- 5. STAGING.DIM_SALESPERSON — Seed the 3 known Reebok associates
-- =============================================================
-- This seed is idempotent. Other salespeople from raw.sales are appended
-- by build_dimensions.py, but these 3 are guaranteed to be present so
-- the staffwise report never has missing rows.
-- =============================================================
-- Seed the 3 known Reebok associates.
-- staging.dim_salesperson has no unique constraint on salesperson_name_raw
-- (it has one on salesperson_key), so use WHERE NOT EXISTS for idempotency.
INSERT INTO staging.dim_salesperson (salesperson_name_raw, salesperson_name, salesperson_code, status)
SELECT * FROM (VALUES
    ('BALRAJ GADDAM'::text,     'Balraj Gaddam'::text,     'REE001'::text, 'Active'::text),
    ('RAMBABU DHARAVATH'::text, 'Rambabu Dharavath'::text, 'REE002'::text, 'Active'::text),
    ('ERRI SRIJA'::text,        'Erri Srija'::text,        'REE003'::text, 'Active'::text)
) AS s(salesperson_name_raw, salesperson_name, salesperson_code, status)
WHERE NOT EXISTS (
    SELECT 1 FROM staging.dim_salesperson
    WHERE staging.dim_salesperson.salesperson_name_raw = s.salesperson_name_raw
);

