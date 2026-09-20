-- =============================================================
-- Reebok data cleanup - STEP 1 of 3: PREVIEW (read-only, changes nothing)
-- =============================================================
-- Run this first in the Supabase SQL editor and keep the result.
-- It shows what the cleanup will remove and what it will keep.
-- Then run 2026_09_21_cleanup_execute.sql, then scripts/cleanup_storage.py.
--
-- Scope (decided 20-Sep-2026): sales and Account DSR data only.
-- Inventory data, reference data, table structures, functions and logins are NOT touched.
-- =============================================================

-- A. Is a processing run active? This must return NO ROWS before you clean up.
select id, status, requested_at
from public.processing_runs
where status in ('queued', 'processing');

-- B. What will be removed / kept
select item, "rows"
from (
  select  1 as ord, 'REMOVE  raw.sales' as item, count(*) as "rows" from raw.sales
  union all select  2, 'REMOVE  raw.account_dsr', count(*) from raw.account_dsr
  union all select  3, 'REMOVE  gold.reebok_daily_metrics', count(*) from gold.reebok_daily_metrics
  union all select  4, 'REMOVE  gold.reebok_master_dashboard', count(*) from gold.reebok_master_dashboard
  union all select  5, 'REMOVE  gold.reebok_master_dashboard_payments', count(*) from gold.reebok_master_dashboard_payments
  union all select  6, 'REMOVE  gold.fact_master_dashboard (old pipeline)', count(*) from gold.fact_master_dashboard
  union all select  7, 'REMOVE  gold.fact_master_dashboard_granular (old pipeline)', count(*) from gold.fact_master_dashboard_granular
  union all select  8, 'REMOVE  gold.fact_master_dashboard_payments (old pipeline)', count(*) from gold.fact_master_dashboard_payments
  union all select  9, 'REMOVE  staging.dim_store junk rows (footer labels)', count(*) from staging.dim_store where site_short_name like '%:'
  union all select 10, 'REMOVE  public.upload_audit_log (sales + account_dsr)', count(*) from public.upload_audit_log where report_type in ('sales', 'account_dsr')
  union all select 11, 'REMOVE  public.processing_runs (no longer referenced)', count(*) from public.processing_runs pr
       where not exists (select 1 from public.upload_audit_log a where a.processing_run_id = pr.id and a.report_type = 'inventory')
  union all select 20, 'KEEP    raw.inventory', count(*) from raw.inventory
  union all select 21, 'KEEP    staging.fact_stock', count(*) from staging.fact_stock
  union all select 22, 'KEEP    public.upload_audit_log (inventory)', count(*) from public.upload_audit_log where report_type = 'inventory'
  union all select 23, 'KEEP    staging.dim_store (real stores)', count(*) from staging.dim_store where site_short_name not like '%:'
  union all select 24, 'KEEP    staging.dim_product', count(*) from staging.dim_product
  union all select 25, 'KEEP    staging.dim_promotion', count(*) from staging.dim_promotion
  union all select 26, 'KEEP    staging.dim_salesperson', count(*) from staging.dim_salesperson
  union all select 27, 'KEEP    staging.dim_date', count(*) from staging.dim_date
  union all select 28, 'KEEP    staging.holiday_reference', count(*) from staging.holiday_reference
) t
order by ord;
