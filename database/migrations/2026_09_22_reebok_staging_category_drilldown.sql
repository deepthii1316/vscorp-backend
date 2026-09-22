-- =============================================================
-- Uppal Reebok — reuse the existing staging star schema + Category Drill-down gold table
-- =============================================================
-- staging.fact_sales / dim_product / dim_store / dim_salesperson / dim_date already exist
-- in schema.sql, but NOTHING ever wrote a row into staging.fact_sales (verified: no INSERT
-- into it anywhere in worker/pipeline). dim_product's division/department columns were also
-- wrong for Reebok: division came straight from the raw "Brand" column, which is always
-- literally "Reebok" — never footwear/apparel/accessories. That mapping is fixed below and
-- in build_dimensions.py (now resolves division/footwear_type the same way
-- refresh_reebok.py's KPI numbers do: resolve_division(), imported from there, not
-- reimplemented, so the two can never silently disagree again).
--
-- Adds:
--   1. staging.dim_product.article_type / footwear_type (new columns; division's existing
--      column now gets a correct value)
--   2. gold.reebok_category_drilldown, built by
--      worker/pipeline/scripts/refresh_category_drilldown.py from
--      staging.fact_sales JOIN dim_product/dim_store/dim_date (real SQL aggregation, not
--      Python-side like the older Reebok gold tables).
-- Populated by build_dimensions() -> refresh_reebok_staging() -> refresh_category_drilldown()
-- in run_pipeline.py, in that order (fact_sales needs the fixed dim_product/dim_store first).
-- =============================================================

ALTER TABLE staging.dim_product
    ADD COLUMN IF NOT EXISTS article_type  text,   -- raw Class Name (Shoes, T Shirt, Socks, ...)
    ADD COLUMN IF NOT EXISTS footwear_type text;    -- 'Closed' (Shoes) / 'Open' (rest of footwear) / NULL for non-footwear

CREATE TABLE IF NOT EXISTS gold.reebok_category_drilldown (
    full_date       date NOT NULL,
    division        text NOT NULL,
    department      text NOT NULL DEFAULT '',
    section         text NOT NULL DEFAULT '',
    article_type    text NOT NULL DEFAULT '',
    footwear_type   text NOT NULL DEFAULT '',   -- '' for non-footwear rows (never NULL, so it can sit in the PK)
    qty             numeric NOT NULL DEFAULT 0,
    mrp_value       numeric NOT NULL DEFAULT 0,
    nsv             numeric NOT NULL DEFAULT 0,
    loaded_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (full_date, division, department, section, article_type, footwear_type)
);

CREATE INDEX IF NOT EXISTS idx_reebok_category_drilldown_date ON gold.reebok_category_drilldown (full_date);

GRANT SELECT ON gold.reebok_category_drilldown TO authenticated, service_role;
GRANT ALL ON gold.reebok_category_drilldown TO postgres, service_role;
