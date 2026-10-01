-- =============================================================
-- Merchandiser Dashboard — RPCs (Uppal Reebok, single store R1157)
-- =============================================================
-- Template: frontend/public/docs/MERCHANDISER_DASHBOARD_REFERENCE.md (Skechers, multi-store).
-- Single store, ~3K EANs: no gold table and no cluster/store/transfer logic. One RPC returns
-- one row per EAN; the page fetches it once and does every rollup, filter and bucket client-side
-- (same "fetch once, slice locally" pattern as the template). Health thresholds are applied in
-- the browser, so changing them needs no refetch.
--
-- as_of = the latest stock snapshot (staging.fact_stock.snapshot_date_key = the day the stock
-- report describes). Sales windows end on as_of:
--   sales_qty_30d / nsv_30d : as_of-29 .. as_of
--   sales_qty_mtd / nsv_mtd : 1st of as_of's month .. as_of
--   rate (cover)            : sales over the last min(182, days the store has traded) days,
--                             "stores open < 6 months: months open" rule from the template §4.
-- Definitions (template §6):
--   age_days  = as_of - Last Inwarded Date
--   idle_days = as_of - GREATEST(last sale, last inward)   (= LEAST(days since sale, age))
--   sell-through % (30d) = sold_30d / (sold_30d + stock) — computed client-side from these sums.
-- Rows: every EAN in the latest snapshot, plus EANs with a sale in the last 30 days and no stock
-- now (sold out), so sell-through and cover never drop a product that sold through.
-- sales_qty_total covers only the returned EANs (in stock, or sold in the last 30 days).
-- Sales come from staging.fact_sales (all sales), never from a stock-grain table (template §8.8).
-- =============================================================

CREATE OR REPLACE FUNCTION public.rpt_merch_sku()
RETURNS TABLE (
    as_of date, store_first_sale date, rate_days integer,
    barcode text, article_name text, style_code text, color text, size text,
    division text, department text, section text, article_type text,
    mrp numeric, unit_cost numeric,
    stock_qty numeric, stock_mrp_value numeric, stock_cost_value numeric,
    last_inward_date date, inward_type text,
    first_sale_date date, last_sale_date date,
    sales_qty_30d numeric, nsv_30d numeric,
    sales_qty_mtd numeric, nsv_mtd numeric,
    sales_qty_rate numeric, sales_qty_total numeric,
    age_days integer, idle_days integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = staging, public
AS $$
WITH snap AS (
    SELECT max(snapshot_date_key) AS k FROM staging.fact_stock
), asof AS (
    SELECT to_date(k::text, 'YYYYMMDD') AS d FROM snap WHERE k IS NOT NULL
), opened AS (
    SELECT min(dd.full_date) AS first_sale
    FROM staging.fact_sales s JOIN staging.dim_date dd ON dd.date_key = s.date_key
), win AS (
    SELECT a.d,
           o.first_sale,
           LEAST(182, GREATEST(1, a.d - COALESCE(o.first_sale, a.d) + 1))::integer AS rate_days
    FROM asof a CROSS JOIN opened o
), stock AS (
    SELECT fs.product_key,
           sum(fs.closing_total_qty)  AS qty,
           sum(fs.stock_mrp_value)    AS mrp_value,
           sum(fs.stock_cost_value)   AS cost_value,
           max(fs.last_received_rate) AS unit_cost,
           max(fs.mrp)                AS mrp,
           max(to_date(fs.last_grn_date_key::text, 'YYYYMMDD')) AS last_inward,
           max(fs.inward_type)        AS inward_type
    FROM staging.fact_stock fs, snap
    WHERE fs.snapshot_date_key = snap.k
    GROUP BY fs.product_key
), sales AS (
    SELECT s.product_key,
           min(dd.full_date) AS first_sale,
           max(dd.full_date) AS last_sale,
           sum(s.quantity)       FILTER (WHERE dd.full_date >  w.d - 30) AS qty_30d,
           sum(s.taxable_amount) FILTER (WHERE dd.full_date >  w.d - 30) AS nsv_30d,
           sum(s.quantity)       FILTER (WHERE dd.full_date >= date_trunc('month', w.d)::date) AS qty_mtd,
           sum(s.taxable_amount) FILTER (WHERE dd.full_date >= date_trunc('month', w.d)::date) AS nsv_mtd,
           sum(s.quantity)       FILTER (WHERE dd.full_date >  w.d - w.rate_days) AS qty_rate,
           sum(s.quantity) AS qty_total
    FROM staging.fact_sales s
    JOIN staging.dim_date dd ON dd.date_key = s.date_key
    CROSS JOIN win w
    WHERE dd.full_date <= w.d
    GROUP BY s.product_key
)
SELECT
    w.d, w.first_sale, w.rate_days,
    p.barcode, p.article_name, p.style_code, p.color, p.size,
    COALESCE(NULLIF(p.division, ''), 'unclassified'),
    COALESCE(NULLIF(p.department, ''), 'Unmapped'),
    COALESCE(NULLIF(p.section, ''), 'Unmapped'),
    COALESCE(NULLIF(p.article_type, ''), 'Unmapped'),
    COALESCE(st.mrp, p.mrp), st.unit_cost,
    COALESCE(st.qty, 0), COALESCE(st.mrp_value, 0), COALESCE(st.cost_value, 0),
    st.last_inward, st.inward_type,
    sa.first_sale, sa.last_sale,
    COALESCE(sa.qty_30d, 0), COALESCE(sa.nsv_30d, 0),
    COALESCE(sa.qty_mtd, 0), COALESCE(sa.nsv_mtd, 0),
    COALESCE(sa.qty_rate, 0), COALESCE(sa.qty_total, 0),
    (w.d - st.last_inward)::integer,
    CASE WHEN st.product_key IS NULL THEN NULL
         ELSE (w.d - GREATEST(st.last_inward, sa.last_sale))::integer END
FROM win w
CROSS JOIN staging.dim_product p
LEFT JOIN stock st ON st.product_key = p.product_key
LEFT JOIN sales sa ON sa.product_key = p.product_key
WHERE (st.product_key IS NOT NULL OR COALESCE(sa.qty_30d, 0) > 0)
  -- Not merchandise: paper carry bags (already excluded from sales, refresh_reebok.EXCLUDED_CLASSES)
  -- and promotional trolleys (MRP 6,999 at ~Rs 51 cost). Together ~1,440 units that would
  -- otherwise swamp Accessories and the dead-stock list.
  AND lower(COALESCE(p.article_type, '')) NOT IN ('carry bag', 'trolley')
$$;

REVOKE ALL ON FUNCTION public.rpt_merch_sku() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpt_merch_sku() TO service_role;


-- Barcode lookup: every sales line and every stock snapshot for one EAN (the row-level detail
-- behind the dashboard's barcode box; identity/stock/sell-through come from rpt_merch_sku).
CREATE OR REPLACE FUNCTION public.rpt_merch_product_history(p_barcode text)
RETURNS TABLE (kind text, full_date date, bill_no text, salesperson text,
               qty numeric, mrp numeric, nsv numeric, stock_qty numeric, inward_date date)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = staging, public
AS $$
    SELECT 'sale', dd.full_date, s.bill_no, sp.salesperson_name,
           s.quantity, s.sale_mrp, s.taxable_amount, NULL::numeric, NULL::date
    FROM staging.fact_sales s
    JOIN staging.dim_product p ON p.product_key = s.product_key
    JOIN staging.dim_date dd ON dd.date_key = s.date_key
    LEFT JOIN staging.dim_salesperson sp ON sp.salesperson_key = s.salesperson_key
    WHERE p.barcode = TRIM(p_barcode)
    UNION ALL
    SELECT 'stock', to_date(fs.snapshot_date_key::text, 'YYYYMMDD'), NULL, NULL,
           NULL, fs.mrp, NULL, fs.closing_total_qty,
           to_date(fs.last_grn_date_key::text, 'YYYYMMDD')
    FROM staging.fact_stock fs
    JOIN staging.dim_product p ON p.product_key = fs.product_key
    WHERE p.barcode = TRIM(p_barcode)
    ORDER BY 2 DESC, 1
$$;

REVOKE ALL ON FUNCTION public.rpt_merch_product_history(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpt_merch_product_history(text) TO service_role;
