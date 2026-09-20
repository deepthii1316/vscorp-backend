-- =============================================================
-- Uppal Reebok — Master Dashboard (Overview) data layer
-- =============================================================
-- Adds:
--   1. Extra Account DSR columns in raw.account_dsr (AMEX, Zomato, GV, day sale, credit notes, ...)
--   2. gold.reebok_master_dashboard           (one row per day: NSV, MRP, qty, bills, division split, socks/shoes)
--   3. gold.reebok_master_dashboard_payments  (one row per day: payment mode split, cleaned and de-duplicated)
--
-- Both gold tables are filled by pipeline/scripts/refresh_reebok.py.
-- The Account DSR loader (ingest_file.py) was changed at the same time to map the
-- real Reebok DSR headers, so DSR files must be RE-UPLOADED after this migration
-- (rows loaded by the old loader do not contain CARD/AMEX/ZOMATO/GV and are ignored).
--
-- Definitions (see frontend/public/REEBOOK_KPI_DEFINITIONS.md):
--   nsv         = SUM(Taxable Amount)
--   gross_value = nsv + GST (what the customer paid)
--   mrp_value   = SUM(MRP x Qty)
--   MD %        = (mrp_value - nsv) / mrp_value x 100   (decided 20-Sep-2026)
-- =============================================================


-- 1. Extra DSR columns (all text, like the rest of raw.*)
ALTER TABLE raw.account_dsr
    ADD COLUMN IF NOT EXISTS "AMEX Amount"        text,
    ADD COLUMN IF NOT EXISTS "Zomato Amount"      text,
    ADD COLUMN IF NOT EXISTS "GV Amount"          text,
    ADD COLUMN IF NOT EXISTS "System Day Sale"    text,
    ADD COLUMN IF NOT EXISTS "Physical Day Sale"  text,
    ADD COLUMN IF NOT EXISTS "Diff"               text,
    ADD COLUMN IF NOT EXISTS "CN Issued"          text,
    ADD COLUMN IF NOT EXISTS "CN Redeem"          text,
    ADD COLUMN IF NOT EXISTS "Cash Used"          text,
    ADD COLUMN IF NOT EXISTS "Paytm Amount"       text,
    ADD COLUMN IF NOT EXISTS "Paytm Card Amount"  text,
    ADD COLUMN IF NOT EXISTS "Remarks"            text;


-- 2. Day-grain sales table for the Overview tab
CREATE TABLE IF NOT EXISTS gold.reebok_master_dashboard (
    full_date           date PRIMARY KEY,
    site_short_name     text NOT NULL DEFAULT 'R1157',
    nsv                 numeric NOT NULL DEFAULT 0,
    gst_amount          numeric NOT NULL DEFAULT 0,
    gross_value         numeric NOT NULL DEFAULT 0,
    mrp_value           numeric NOT NULL DEFAULT 0,
    qty                 numeric NOT NULL DEFAULT 0,
    bills               integer NOT NULL DEFAULT 0,
    footwear_qty        numeric NOT NULL DEFAULT 0,
    footwear_nsv        numeric NOT NULL DEFAULT 0,
    footwear_mrp        numeric NOT NULL DEFAULT 0,
    footwear_bills      integer NOT NULL DEFAULT 0,
    apparel_qty         numeric NOT NULL DEFAULT 0,
    apparel_nsv         numeric NOT NULL DEFAULT 0,
    apparel_mrp         numeric NOT NULL DEFAULT 0,
    apparel_bills       integer NOT NULL DEFAULT 0,
    accessories_qty     numeric NOT NULL DEFAULT 0,
    accessories_nsv     numeric NOT NULL DEFAULT 0,
    accessories_mrp     numeric NOT NULL DEFAULT 0,
    accessories_bills   integer NOT NULL DEFAULT 0,
    socks_qty           numeric NOT NULL DEFAULT 0,
    shoes_qty           numeric NOT NULL DEFAULT 0,
    loaded_at           timestamptz NOT NULL DEFAULT now()
);

-- 3. Day-grain payment split (Account DSR), one row per date
CREATE TABLE IF NOT EXISTS gold.reebok_master_dashboard_payments (
    full_date           date PRIMARY KEY,
    site_short_name     text NOT NULL DEFAULT 'R1157',
    upi_amount          numeric NOT NULL DEFAULT 0,
    card_amount         numeric NOT NULL DEFAULT 0,
    amex_amount         numeric NOT NULL DEFAULT 0,
    zomato_amount       numeric NOT NULL DEFAULT 0,
    gv_amount           numeric NOT NULL DEFAULT 0,
    cash_amount         numeric NOT NULL DEFAULT 0,
    total_collected     numeric NOT NULL DEFAULT 0,   -- sum of the six modes above
    dsr_day_sale        numeric,                      -- PHYSICAL DAY SALE as reported in the DSR (reference only)
    cash_used           numeric,
    cn_issued           numeric,
    cn_redeem           numeric,
    remarks             text,
    source_file         text,
    loaded_at           timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON gold.reebok_master_dashboard, gold.reebok_master_dashboard_payments TO authenticated, service_role;
GRANT ALL ON gold.reebok_master_dashboard, gold.reebok_master_dashboard_payments TO postgres, service_role;
