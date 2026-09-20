-- =============================================================
-- Inventory data cleanup - STEP 2 of 3: EXECUTE (destructive)
-- =============================================================
-- Run only after:
--   * the inventory preview has been run and its numbers reviewed,
--   * the original stock report files are safe outside the app,
--   * the backend with the fixed inventory loader ("Grand Total:" lines) has been pushed.
--
-- What it does (ONE transaction: if anything fails, nothing changes):
--   1. Refuses to run if a processing run is queued or processing, or an upload is waiting.
--   2. Empties raw.inventory (row ids restart from 1).
--   3. Empties the staging tables built from inventory/sales: fact_stock, fact_sales, dim_product, dim_promotion.
--      They are rebuilt by the next processing run.
--   4. Removes the inventory upload records (so the same stock files can be uploaded again).
--
-- NOT touched: raw.sales, raw.account_dsr, gold tables, sales/DSR upload records, dim_store,
-- dim_salesperson, dim_date, holiday_reference, functions, table definitions, Supabase Auth.
-- =============================================================

begin;

-- 1. Safety check
do $$
begin
  if exists (select 1 from public.processing_runs where status in ('queued', 'processing')) then
    raise exception 'A processing run is queued or processing. Wait for it to finish, then run this again.';
  end if;
  if exists (select 1 from public.upload_audit_log where status in ('queued', 'pending', 'uploaded')) then
    raise exception 'An upload is waiting to be processed. Process it (or remove it) first, then run this again.';
  end if;
end $$;

-- 2 + 3. Raw inventory and the derived staging tables (all tables that reference dim_product are listed,
--        so no CASCADE is needed and nothing else can be emptied by accident)
truncate table raw.inventory restart identity;
truncate table staging.fact_stock, staging.fact_sales, staging.dim_product, staging.dim_promotion restart identity;

-- 4. Inventory upload records (includes the one stuck in "processing")
delete from public.upload_audit_log where report_type = 'inventory';

commit;

-- 5. Result: every REMOVED line should be 0 and every KEPT line should equal the preview
select item, "rows"
from (
  select  1 as ord, 'REMOVED raw.inventory' as item, count(*) as "rows" from raw.inventory
  union all select  2, 'REMOVED staging.fact_stock', count(*) from staging.fact_stock
  union all select  3, 'REMOVED staging.fact_sales', count(*) from staging.fact_sales
  union all select  4, 'REMOVED staging.dim_product', count(*) from staging.dim_product
  union all select  5, 'REMOVED staging.dim_promotion', count(*) from staging.dim_promotion
  union all select  6, 'REMOVED upload_audit_log (inventory)', count(*) from public.upload_audit_log where report_type = 'inventory'
  union all select 20, 'KEPT    raw.sales', count(*) from raw.sales
  union all select 21, 'KEPT    raw.account_dsr', count(*) from raw.account_dsr
  union all select 22, 'KEPT    gold.reebok_master_dashboard', count(*) from gold.reebok_master_dashboard
  union all select 23, 'KEPT    upload_audit_log (sales + account_dsr)', count(*) from public.upload_audit_log where report_type <> 'inventory'
  union all select 24, 'KEPT    staging.dim_store', count(*) from staging.dim_store
  union all select 25, 'KEPT    staging.dim_salesperson', count(*) from staging.dim_salesperson
  union all select 26, 'KEPT    staging.dim_date', count(*) from staging.dim_date
  union all select 27, 'KEPT    staging.holiday_reference', count(*) from staging.holiday_reference
) t
order by ord;
