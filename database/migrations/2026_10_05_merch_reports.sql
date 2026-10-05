-- =============================================================
-- Merchandiser Reports — RPC (Uppal Reebok, single store R1157)
-- =============================================================
-- Feeds the Merch Reports page (Division Summary / Footwear / Apparel / Data), the emailed-image
-- and Excel twin of the manager's hand-built "Reebok_Merchandiser_Stock_Report.xlsx".
-- One row per EAN; the API rolls it up into the report tables (same "one row per EAN, roll up
-- in the app" pattern as rpt_merch_sku).
--
-- as_of = the latest stock snapshot (same as the Merch Dashboard). Sales windows end on as_of:
--   sales_qty_mtd : 1st of as_of's month .. as_of
--   sales_qty_ytd : the most recent 1 July on or before as_of .. as_of (same YTD as the sales
--                   reports, refresh_reebok.ytd_start)
--   sell-through YTD = sales_qty_ytd / (sales_qty_ytd + stock_qty) — computed in the app from sums.
-- Rows: every EAN in the latest snapshot, plus every EAN sold in the YTD window that is no longer
-- in stock. rpt_merch_sku only keeps sold-out EANs from the last 30 days, which on 4 Oct 2026
-- counted 700 of the 1,259 units sold since 1 July — so YTD must not be read from it.
--
-- Classification (group / department / category / subclass) is the stock file's own for an EAN
-- in the latest stock file, so the report ties to a pivot of that file; an EAN that has sold out
-- takes it from its latest sales line. Division is staging.dim_product.division
-- (refresh_reebok.resolve_division), which already places the blank-"Item Division" SKUs that the
-- manager's workbook mapped by hand on its Category_Map sheet.
--
-- Not merchandise, left out of stock and sales: paper carry bags, and everything the source tags
-- Sub Class = 'Promotional Item' (promo trolley, promo bags — free add-ons on Rs 9,999 / 18,000
-- bills). The Merch Dashboard used to drop only carry bags and the trolley; rpt_merch_sku is
-- redefined below with the same rule so the dashboard and the report agree.
-- Stock value is at MRP only.
-- =============================================================

CREATE OR REPLACE FUNCTION public.merch_promo_barcodes()
RETURNS SETOF text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = raw, public
AS $$
    SELECT TRIM("Bar Code") FROM raw.inventory
    WHERE lower(TRIM("Sub Class")) = 'promotional item' AND NULLIF(TRIM("Bar Code"), '') IS NOT NULL
    UNION
    SELECT TRIM("Bar Code") FROM raw.sales
    WHERE lower(TRIM("Sub Class")) = 'promotional item' AND NULLIF(TRIM("Bar Code"), '') IS NOT NULL
$$;

REVOKE ALL ON FUNCTION public.merch_promo_barcodes() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merch_promo_barcodes() TO service_role;


CREATE OR REPLACE FUNCTION public.rpt_merch_report_sku()
RETURNS TABLE (
    as_of date, mtd_from date, ytd_from date,
    barcode text, division text, group_name text, department text, category text, subclass text,
    style_code text, product_name text, size text,
    mrp numeric, stock_qty numeric, stock_mrp_value numeric, last_inward_date date,
    sales_qty_mtd numeric, sales_qty_ytd numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = staging, raw, public
AS $$
WITH snap AS (
    SELECT max(snapshot_date_key) AS k FROM staging.fact_stock
), win AS (
    SELECT a.d,
           date_trunc('month', a.d)::date AS mtd_from,
           make_date(extract(year FROM a.d)::integer
                     - CASE WHEN extract(month FROM a.d) >= 7 THEN 0 ELSE 1 END, 7, 1) AS ytd_from
    FROM (SELECT to_date(k::text, 'YYYYMMDD') AS d FROM snap WHERE k IS NOT NULL) a
), stock_file AS (
    -- The file behind the latest snapshot: latest upload for that Stock Date (refresh_stock rule).
    SELECT i.upload_audit_id
    FROM raw.inventory i, win w
    WHERE i."Stock Date" = to_char(w.d, 'YYYY-MM-DD') AND i.upload_audit_id IS NOT NULL
    ORDER BY i.uploaded_at DESC
    LIMIT 1
), inv AS (
    SELECT DISTINCT ON (TRIM(i."Bar Code"))
           TRIM(i."Bar Code") AS barcode,
           i."Section" AS group_name, i."Category" AS department,
           i."Class Name" AS category, i."Sub Class" AS subclass,
           i."Style Code" AS style_code, i."Item Description" AS product_name, i."Size" AS size
    FROM raw.inventory i
    JOIN stock_file f ON f.upload_audit_id = i.upload_audit_id
    WHERE NULLIF(TRIM(i."Bar Code"), '') IS NOT NULL
    ORDER BY TRIM(i."Bar Code"), i.source_row_number
), sold AS (
    SELECT DISTINCT ON (TRIM(r."Bar Code"))
           TRIM(r."Bar Code") AS barcode,
           r."Section" AS group_name, r."Category" AS department,
           r."Class Name" AS category, r."Sub Class" AS subclass,
           r."Style Code" AS style_code
    FROM raw.sales r
    WHERE NULLIF(TRIM(r."Bar Code"), '') IS NOT NULL
    ORDER BY TRIM(r."Bar Code"), r.id DESC
), stock AS (
    SELECT fs.product_key,
           sum(fs.closing_total_qty) AS qty,
           sum(fs.stock_mrp_value)   AS mrp_value,
           max(fs.mrp)               AS mrp,
           max(to_date(fs.last_grn_date_key::text, 'YYYYMMDD')) AS last_inward
    FROM staging.fact_stock fs, snap
    WHERE fs.snapshot_date_key = snap.k
    GROUP BY fs.product_key
), sales AS (
    SELECT s.product_key,
           sum(s.quantity) FILTER (WHERE dd.full_date >= w.mtd_from) AS qty_mtd,
           sum(s.quantity) AS qty_ytd
    FROM staging.fact_sales s
    JOIN staging.dim_date dd ON dd.date_key = s.date_key
    CROSS JOIN win w
    WHERE dd.full_date >= w.ytd_from AND dd.full_date <= w.d
    GROUP BY s.product_key
)
SELECT
    w.d, w.mtd_from, w.ytd_from,
    p.barcode,
    upper(COALESCE(NULLIF(p.division, ''), 'unclassified')),
    COALESCE(NULLIF(TRIM(COALESCE(i.group_name, so.group_name)), ''), 'Unmapped'),
    COALESCE(NULLIF(TRIM(COALESCE(i.department, so.department)), ''), 'Unmapped'),
    COALESCE(NULLIF(TRIM(COALESCE(i.category, so.category)), ''), 'Unmapped'),
    COALESCE(NULLIF(TRIM(COALESCE(i.subclass, so.subclass)), ''), 'Unmapped'),
    COALESCE(NULLIF(TRIM(COALESCE(i.style_code, so.style_code)), ''), p.style_code),
    COALESCE(NULLIF(TRIM(i.product_name), ''), p.article_name),
    COALESCE(NULLIF(TRIM(i.size), ''), p.size),
    COALESCE(st.mrp, p.mrp),
    COALESCE(st.qty, 0), COALESCE(st.mrp_value, 0), st.last_inward,
    COALESCE(sa.qty_mtd, 0), COALESCE(sa.qty_ytd, 0)
FROM win w
CROSS JOIN staging.dim_product p
LEFT JOIN stock st ON st.product_key = p.product_key
LEFT JOIN sales sa ON sa.product_key = p.product_key
LEFT JOIN inv i    ON i.barcode = p.barcode
LEFT JOIN sold so  ON so.barcode = p.barcode
WHERE (st.product_key IS NOT NULL OR COALESCE(sa.qty_ytd, 0) <> 0 OR COALESCE(sa.qty_mtd, 0) <> 0)
  AND lower(COALESCE(p.article_type, '')) <> 'carry bag'
  AND p.barcode NOT IN (SELECT public.merch_promo_barcodes())
$$;

REVOKE ALL ON FUNCTION public.rpt_merch_report_sku() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpt_merch_report_sku() TO service_role;


-- Merch Dashboard: same body as 2026_10_02_merch_dashboard_rpcs.sql, with the promotional items
-- added to the "not merchandise" filter (was: carry bags and the trolley only).
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
  -- and promotional items (trolley, promo bags: free add-ons on high-value bills, MRP in the
  -- thousands at ~Rs 20-50 cost) that would otherwise swamp Accessories and the dead-stock list.
  AND lower(COALESCE(p.article_type, '')) NOT IN ('carry bag', 'trolley')
  AND p.barcode NOT IN (SELECT public.merch_promo_barcodes())
$$;

REVOKE ALL ON FUNCTION public.rpt_merch_sku() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpt_merch_sku() TO service_role;
