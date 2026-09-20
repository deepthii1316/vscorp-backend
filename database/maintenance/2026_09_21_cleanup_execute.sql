-- =============================================================
-- Reebok data cleanup - STEP 2 of 3: EXECUTE (destructive)
-- =============================================================
-- Run only after:
--   * the preview script has been run and its numbers reviewed,
--   * the original Excel files for every period are safe outside the app,
--   * the backend with the fixed sales loader (footer lines) has been pushed.
--
-- What it does (all inside ONE transaction; if anything fails, nothing changes):
--   1. Refuses to run if a processing run is queued or processing.
--   2. Empties raw.sales and raw.account_dsr (row ids restart from 1).
--   3. Empties every gold table (the new Reebok ones and the three old-pipeline ones).
--   4. Removes the 3 junk store rows created from the sales footer lines.
--   5. Removes the sales and account_dsr upload records (so the same files can be uploaded again),
--      then the processing-run history that no longer has any record pointing at it.
--
-- NOT touched: raw.inventory, staging.fact_stock, inventory upload records, dim_product, dim_promotion,
-- dim_salesperson, dim_date, holiday_reference, all functions and table definitions, Supabase Auth.
-- (The next processing run rebuilds the staging dimensions from the new uploads by itself.)
-- =============================================================

begin;

-- 1. Safety check
do $$
begin
  if exists (select 1 from public.processing_runs where status in ('queued', 'processing')) then
    raise exception 'A processing run is queued or processing. Wait for it to finish (or release it), then run this again.';
  end if;
end $$;

-- 2. Raw data (children of upload_audit_log, so these go first)
truncate table raw.sales, raw.account_dsr restart identity;

-- 3. Gold tables
truncate table
  gold.reebok_daily_metrics,
  gold.reebok_master_dashboard,
  gold.reebok_master_dashboard_payments,
  gold.fact_master_dashboard,
  gold.fact_master_dashboard_granular,
  gold.fact_master_dashboard_payments
restart identity;

-- 4. Junk store rows (only if nothing points at them)
delete from staging.dim_store s
where s.site_short_name like '%:'
  and not exists (select 1 from staging.fact_stock f where f.store_key = s.store_key)
  and not exists (select 1 from staging.fact_sales f where f.store_key = s.store_key);

-- 5. Upload records for sales and Account DSR, then unreferenced processing runs
delete from public.upload_audit_log where report_type in ('sales', 'account_dsr');

delete from public.processing_runs pr
where not exists (select 1 from public.upload_audit_log a where a.processing_run_id = pr.id)
  and not exists (select 1 from public.report_email_deliveries d where d.processing_run_id = pr.id);

commit;

-- 6. Result: every REMOVE line should be 0 and every KEEP line should equal the preview
select item, "rows"
from (
  select  1 as ord, 'REMOVED raw.sales' as item, count(*) as "rows" from raw.sales
  union all select  2, 'REMOVED raw.account_dsr', count(*) from raw.account_dsr
  union all select  3, 'REMOVED gold.reebok_daily_metrics', count(*) from gold.reebok_daily_metrics
  union all select  4, 'REMOVED gold.reebok_master_dashboard', count(*) from gold.reebok_master_dashboard
  union all select  5, 'REMOVED gold.reebok_master_dashboard_payments', count(*) from gold.reebok_master_dashboard_payments
  union all select  6, 'REMOVED gold.fact_master_dashboard', count(*) from gold.fact_master_dashboard
  union all select  7, 'REMOVED gold.fact_master_dashboard_granular', count(*) from gold.fact_master_dashboard_granular
  union all select  8, 'REMOVED gold.fact_master_dashboard_payments', count(*) from gold.fact_master_dashboard_payments
  union all select  9, 'REMOVED junk dim_store rows', count(*) from staging.dim_store where site_short_name like '%:'
  union all select 10, 'REMOVED upload_audit_log sales + account_dsr', count(*) from public.upload_audit_log where report_type in ('sales', 'account_dsr')
  union all select 11, 'REMOVED processing_runs', count(*) from public.processing_runs
  union all select 20, 'KEPT    raw.inventory', count(*) from raw.inventory
  union all select 21, 'KEPT    staging.fact_stock', count(*) from staging.fact_stock
  union all select 22, 'KEPT    upload_audit_log (inventory)', count(*) from public.upload_audit_log where report_type = 'inventory'
  union all select 23, 'KEPT    staging.dim_store (real stores)', count(*) from staging.dim_store
  union all select 24, 'KEPT    staging.dim_product', count(*) from staging.dim_product
  union all select 25, 'KEPT    staging.dim_promotion', count(*) from staging.dim_promotion
  union all select 26, 'KEPT    staging.dim_salesperson', count(*) from staging.dim_salesperson
  union all select 27, 'KEPT    staging.dim_date', count(*) from staging.dim_date
  union all select 28, 'KEPT    staging.holiday_reference', count(*) from staging.holiday_reference
) t
order by ord;
