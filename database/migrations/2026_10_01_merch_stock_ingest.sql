-- =============================================================
-- Merchandiser Dashboard, Phase 0: make stock data joinable to sales
-- =============================================================
-- Profiling (2026-10-01) found the stock pipeline unusable for any stock-vs-sales metric:
--   * raw.inventory."Bar Code" held the Style Code, not the EAN. The ingest matched headers
--     by substring and tried "Style Code" before "EAN", so 0 stock rows joined to
--     staging.dim_product's sales barcodes (sales "Bar Code" IS the EAN).
--   * "Last Inwarded Date" (stock age), Unit Cost, Cost Value, MRP Value, Class Name
--     ("Category" in the file), Subclass, Color and Style Code were dropped.
--   * "Stock Value" was "Total Stock With Tax" (cost + GST) and was written into
--     fact_stock.last_received_rate, a misnamed column.
--   * snapshot_date_key was the upload date, not the date the stock report describes.
--   * 6 of 8 "Stock Balance Report" files loaded 0 rows yet were marked completed: from
--     2026-09-23 onward the export puts a pivot sheet first and the ingest read only sheet 1.
--
-- The join key between sales and stock is the EAN (sales "Bar Code" = stock "EAN"; one stock
-- row per EAN). Style Code (+ Color) groups the sizes of one article.
--
-- Raw columns stay text (hard rule 5). Existing columns keep the meaning the sales ingest gives
-- them: "Bar Code" = EAN, "Brand" = DIVISION, "Section" = Group Name (gender),
-- "Category" = Department, "Stock Value" = Total Stock With Tax.
-- =============================================================

ALTER TABLE raw.inventory
    ADD COLUMN IF NOT EXISTS "Stock Date"         text,   -- YYYY-MM-DD the snapshot describes (from the export filename)
    ADD COLUMN IF NOT EXISTS "SKU"                text,
    ADD COLUMN IF NOT EXISTS "Style Code"         text,
    ADD COLUMN IF NOT EXISTS "Item Division"      text,
    ADD COLUMN IF NOT EXISTS "Class Name"         text,   -- source column "Category" (Shoes, Polo, ...), same as sales "Class Name"
    ADD COLUMN IF NOT EXISTS "Sub Class"          text,   -- source column "Subclass"
    ADD COLUMN IF NOT EXISTS "Color"              text,
    ADD COLUMN IF NOT EXISTS "Gender"             text,
    ADD COLUMN IF NOT EXISTS "Last Inwarded Date" text,   -- YYYY-MM-DD
    ADD COLUMN IF NOT EXISTS "Inward Type"        text,
    ADD COLUMN IF NOT EXISTS "Unit Cost"          text,
    ADD COLUMN IF NOT EXISTS "Cost Value"         text,   -- qty x unit cost, ex tax
    ADD COLUMN IF NOT EXISTS "MRP Value"          text;   -- source column "Value" = qty x MRP

ALTER TABLE staging.dim_product
    ADD COLUMN IF NOT EXISTS style_code text,
    ADD COLUMN IF NOT EXISTS size       text;

-- last_received_rate now holds the Unit Cost it is named after; last_grn_date_key holds
-- Last Inwarded Date. Values are split so the dashboard can show MRP or cost value.
ALTER TABLE staging.fact_stock
    ADD COLUMN IF NOT EXISTS mrp                  numeric,
    ADD COLUMN IF NOT EXISTS stock_mrp_value      numeric,
    ADD COLUMN IF NOT EXISTS stock_cost_value     numeric,
    ADD COLUMN IF NOT EXISTS stock_value_with_tax numeric,
    ADD COLUMN IF NOT EXISTS inward_type          text;

CREATE INDEX IF NOT EXISTS idx_fact_stock_snapshot_product
    ON staging.fact_stock (snapshot_date_key, product_key);
CREATE INDEX IF NOT EXISTS idx_raw_inventory_upload
    ON raw.inventory (upload_audit_id);
