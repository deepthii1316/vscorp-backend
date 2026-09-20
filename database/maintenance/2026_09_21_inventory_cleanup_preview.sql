-- =============================================================
-- Inventory data cleanup - STEP 1 of 3: PREVIEW (read-only, changes nothing)
-- =============================================================
-- Run this first in the Supabase SQL editor and keep the result.
-- Then run 2026_09_21_inventory_cleanup_execute.sql, then
--   .\.venv\Scripts\python.exe scripts\cleanup_storage.py --target inventory --execute
--
-- Scope: inventory data only (raw.inventory, staging.fact_stock, inventory upload records, inventory files)
-- plus the two staging dimension tables that are built from sales AND inventory (dim_product, dim_promotion),
-- because they are rebuilt automatically by the next processing run.
-- Sales, Account DSR, the gold tables, reference data, table structures, functions and logins are NOT touched.
-- =============================================================

-- A. Is a processing run active, or an upload waiting to be processed? This must return NO ROWS.
select 'processing run' as what, id::text as ref, status
from public.processing_runs
where status in ('queued', 'processing')
union all
select 'waiting upload', original_file_name, status
from public.upload_audit_log
where status in ('queued', 'pending', 'uploaded');

-- B. The inventory upload records that will be removed (one may be stuck in "processing")
select id, status, original_file_name, uploaded_at::date as uploaded, row_count
from public.upload_audit_log
where report_type = 'inventory'
order by uploaded_at;

-- C. What will be removed / kept
select item, "rows"
from (
  select  1 as ord, 'REMOVE  raw.inventory' as item, count(*) as "rows" from raw.inventory
  union all select  2, 'REMOVE  raw.inventory: "Grand Total:" lines stored as products', count(*) from raw.inventory where "Bar Code" ilike '%total%'
  union all select  3, 'REMOVE  staging.fact_stock', count(*) from staging.fact_stock
  union all select  4, 'REMOVE  staging.fact_sales (empty, derived)', count(*) from staging.fact_sales
  union all select  5, 'REMOVE  staging.dim_product (derived, rebuilt by next run)', count(*) from staging.dim_product
  union all select  6, 'REMOVE  staging.dim_promotion (derived, rebuilt by next run)', count(*) from staging.dim_promotion
  union all select  7, 'REMOVE  public.upload_audit_log (inventory)', count(*) from public.upload_audit_log where report_type = 'inventory'
  union all select 20, 'KEEP    raw.sales', count(*) from raw.sales
  union all select 21, 'KEEP    raw.account_dsr', count(*) from raw.account_dsr
  union all select 22, 'KEEP    gold.reebok_master_dashboard', count(*) from gold.reebok_master_dashboard
  union all select 23, 'KEEP    public.upload_audit_log (sales + account_dsr)', count(*) from public.upload_audit_log where report_type <> 'inventory'
  union all select 24, 'KEEP    staging.dim_store', count(*) from staging.dim_store
  union all select 25, 'KEEP    staging.dim_salesperson', count(*) from staging.dim_salesperson
  union all select 26, 'KEEP    staging.dim_date', count(*) from staging.dim_date
  union all select 27, 'KEEP    staging.holiday_reference', count(*) from staging.holiday_reference
) t
order by ord;
