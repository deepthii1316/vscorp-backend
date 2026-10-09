-- =============================================================
-- RLS on the two gold tables that were left without it
-- =============================================================
-- Supabase lint "RLS Disabled in Public" on gold.reebok_footfall and
-- gold.reebok_category_drilldown. The gold schema is reachable through the Data API, and both
-- tables had row level security OFF while anon / authenticated held SELECT and INSERT/UPDATE/
-- DELETE — so anyone holding the browser (anon) key could read and rewrite them.
--
-- Fix, same as every other gold / staging / raw table: RLS ON with no policies (deny-all for the
-- API roles) and no table privileges for anon / authenticated. Nothing in the app is affected:
--   * server routes read with the service-role key, which bypasses RLS;
--   * the pipeline writes as the table owner (postgres), which bypasses RLS;
--   * the browser key is only ever used for login and the user's own row in public.users.
-- Safe to re-run.
-- =============================================================

ALTER TABLE gold.reebok_footfall            ENABLE ROW LEVEL SECURITY;
ALTER TABLE gold.reebok_category_drilldown  ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON gold.reebok_footfall, gold.reebok_category_drilldown FROM PUBLIC, anon, authenticated;
GRANT ALL ON gold.reebok_footfall, gold.reebok_category_drilldown TO service_role;
