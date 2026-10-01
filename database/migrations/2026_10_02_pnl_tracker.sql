-- =============================================================
-- P&L Tracker (Uppal Reebok) — schema + locked-down access
-- =============================================================
-- Origin: frontend branch `pnl-tracker` (supabase/schema_pnl_tracker.sql, Deeksha, 01-Oct-2026),
-- already applied to the database. This migration is safe to re-run on top of it and fixes:
--   * Policies "Allow all access ... FOR ALL USING (true)" on every table, to role PUBLIC — anyone
--     holding the browser key could have read or rewritten the P&L the moment the schema was
--     exposed to the Data API. Dropped. RLS stays ON with no policies (deny-all), and anon /
--     authenticated get no privileges. Only service_role (server routes) reaches the data, and
--     only through the two functions below — pnl_tracker is NOT added to the exposed schemas.
--   * The page's API read public.stores / public.monthly_pnl (wrong schema) and could never work.
-- Access is admin-only, enforced in the API routes (requireAuth(['admin'])).
-- =============================================================

CREATE SCHEMA IF NOT EXISTS pnl_tracker;

CREATE TABLE IF NOT EXISTS pnl_tracker.stores (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  store_code TEXT UNIQUE,
  brand TEXT DEFAULT 'Regular',
  carpet_sqft INTEGER,
  grade TEXT,
  type TEXT,
  capex NUMERIC,
  rental_deposit NUMERIC,
  stock_deposit NUMERIC,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS pnl_tracker.expense_categories (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  group_name TEXT,
  sort_order INTEGER,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS pnl_tracker.monthly_pnl (
  id BIGSERIAL PRIMARY KEY,
  store_id BIGINT NOT NULL REFERENCES pnl_tracker.stores(id),
  period_month DATE NOT NULL,
  gross_sale NUMERIC,
  discounts NUMERIC,
  gst NUMERIC,
  net_sales NUMERIC,
  income_margin NUMERIC,
  depreciation NUMERIC,
  funds_cost NUMERIC,
  opex_expenses NUMERIC,
  operating_profit NUMERIC,
  net_profit_opex_dep NUMERIC,
  net_profit_opex_dep_funds NUMERIC,
  roi NUMERIC,
  breakeven_opex NUMERIC,
  breakeven_opex_capex NUMERIC,
  breakeven_opex_capex_interest NUMERIC,
  sales_per_sqft NUMERIC,
  import_source TEXT,
  import_date TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  UNIQUE (store_id, period_month)
);

CREATE TABLE IF NOT EXISTS pnl_tracker.monthly_expense_lines (
  id BIGSERIAL PRIMARY KEY,
  monthly_pnl_id BIGINT NOT NULL REFERENCES pnl_tracker.monthly_pnl(id) ON DELETE CASCADE,
  category_id BIGINT NOT NULL REFERENCES pnl_tracker.expense_categories(id),
  amount NUMERIC NOT NULL DEFAULT 0,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  UNIQUE (monthly_pnl_id, category_id)
);

-- Lock down: RLS on, no policies, no grants to API roles.
ALTER TABLE pnl_tracker.stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE pnl_tracker.expense_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE pnl_tracker.monthly_pnl ENABLE ROW LEVEL SECURITY;
ALTER TABLE pnl_tracker.monthly_expense_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow all access to stores" ON pnl_tracker.stores;
DROP POLICY IF EXISTS "Allow all access to expense_categories" ON pnl_tracker.expense_categories;
DROP POLICY IF EXISTS "Allow all access to monthly_pnl" ON pnl_tracker.monthly_pnl;
DROP POLICY IF EXISTS "Allow all access to monthly_expense_lines" ON pnl_tracker.monthly_expense_lines;
REVOKE ALL ON ALL TABLES IN SCHEMA pnl_tracker FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SCHEMA pnl_tracker FROM PUBLIC, anon, authenticated;

INSERT INTO pnl_tracker.stores (name, store_code, brand, carpet_sqft, capex, rental_deposit, stock_deposit)
VALUES ('REEBOK UPPAL', '323865', 'Regular', 1200, 5330536, 1260000, 1800000)
ON CONFLICT (name) DO NOTHING;

INSERT INTO pnl_tracker.expense_categories (name, group_name, sort_order) VALUES
  ('Rent + CAM', 'Occupancy', 1),
  ('Staff Salaries', 'Staffing', 2),
  ('Electricity Bill', 'Occupancy', 3),
  ('Telephone & Internet', 'Occupancy', 4),
  ('Petty Cash', 'Other', 5),
  ('House Keeping', 'Other', 6),
  ('Staff Incentives', 'Staffing', 7),
  ('Bank EDC Charges', 'Other', 8),
  ('Bank UPI Charges', 'Other', 9)
ON CONFLICT (name) DO NOTHING;


-- ─── Read: one row per month, with the expense lines and the derived profit figures ──────────
-- opex = Σ expense lines; operating profit = income margin − opex;
-- net profit = operating profit − depreciation; net (all costs) = net profit − funds cost.
CREATE OR REPLACE FUNCTION public.pnl_monthly(p_store_code text DEFAULT '323865')
RETURNS TABLE (
  period_month date, store_name text, store_code text, carpet_sqft integer, capex numeric,
  gross_sale numeric, income_margin numeric, depreciation numeric, funds_cost numeric, roi numeric,
  opex_expenses numeric, operating_profit numeric, net_profit_opex_dep numeric, net_profit_all_costs numeric,
  expenses jsonb, import_source text, updated_at timestamp
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pnl_tracker, public
AS $$
  SELECT mp.period_month, s.name, s.store_code, s.carpet_sqft, s.capex,
         mp.gross_sale, mp.income_margin, mp.depreciation, mp.funds_cost, mp.roi,
         COALESCE(x.opex, 0),
         COALESCE(mp.income_margin, 0) - COALESCE(x.opex, 0),
         COALESCE(mp.income_margin, 0) - COALESCE(x.opex, 0) - COALESCE(mp.depreciation, 0),
         COALESCE(mp.income_margin, 0) - COALESCE(x.opex, 0) - COALESCE(mp.depreciation, 0) - COALESCE(mp.funds_cost, 0),
         COALESCE(x.lines, '[]'::jsonb),
         mp.import_source, mp.updated_at
  FROM pnl_tracker.monthly_pnl mp
  JOIN pnl_tracker.stores s ON s.id = mp.store_id
  LEFT JOIN LATERAL (
    SELECT sum(l.amount) AS opex,
           jsonb_agg(jsonb_build_object('category', c.name, 'group', c.group_name, 'amount', l.amount)
                     ORDER BY c.sort_order) AS lines
    FROM pnl_tracker.monthly_expense_lines l
    JOIN pnl_tracker.expense_categories c ON c.id = l.category_id
    WHERE l.monthly_pnl_id = mp.id
  ) x ON true
  WHERE s.store_code = p_store_code
  ORDER BY mp.period_month
$$;

CREATE OR REPLACE FUNCTION public.pnl_expense_categories()
RETURNS TABLE (name text, group_name text, sort_order integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pnl_tracker, public
AS $$ SELECT name, group_name, sort_order FROM pnl_tracker.expense_categories ORDER BY sort_order $$;


-- ─── Write: upsert whole months in ONE transaction ──────────────────────────────────────────
-- p_rows: [{ "period_month": "2026-07-01", "gross_sale": n, "income_margin": n,
--            "depreciation": n, "funds_cost": n, "roi": n, "expenses": { "<category>": n, ... } }]
-- A month's expense lines are replaced wholesale (a category missing from the file is removed,
-- not left over from an older import). Unknown categories abort the whole import.
CREATE OR REPLACE FUNCTION public.pnl_import(p_rows jsonb, p_store_code text DEFAULT '323865')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pnl_tracker, public
AS $$
DECLARE
  v_store bigint;
  v_row jsonb;
  v_month date;
  v_pnl bigint;
  v_cat text;
  v_amt text;
  v_cat_id bigint;
  v_saved text[] := '{}';
BEGIN
  SELECT id INTO v_store FROM pnl_tracker.stores WHERE store_code = p_store_code;
  IF v_store IS NULL THEN RAISE EXCEPTION 'Store % not found in pnl_tracker.stores', p_store_code; END IF;
  IF jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'No months to import';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_month := date_trunc('month', (v_row->>'period_month')::date)::date;
    INSERT INTO pnl_tracker.monthly_pnl
      (store_id, period_month, gross_sale, income_margin, depreciation, funds_cost, roi,
       import_source, import_date, updated_at)
    VALUES (v_store, v_month,
            (v_row->>'gross_sale')::numeric, (v_row->>'income_margin')::numeric,
            (v_row->>'depreciation')::numeric, (v_row->>'funds_cost')::numeric, (v_row->>'roi')::numeric,
            'excel', now(), now())
    ON CONFLICT (store_id, period_month) DO UPDATE SET
      gross_sale = EXCLUDED.gross_sale, income_margin = EXCLUDED.income_margin,
      depreciation = EXCLUDED.depreciation, funds_cost = EXCLUDED.funds_cost, roi = EXCLUDED.roi,
      import_source = 'excel', import_date = now(), updated_at = now()
    RETURNING id INTO v_pnl;

    DELETE FROM pnl_tracker.monthly_expense_lines WHERE monthly_pnl_id = v_pnl;
    FOR v_cat, v_amt IN SELECT key, value #>> '{}' FROM jsonb_each(COALESCE(v_row->'expenses', '{}'::jsonb)) LOOP
      SELECT id INTO v_cat_id FROM pnl_tracker.expense_categories WHERE name = v_cat;
      IF v_cat_id IS NULL THEN RAISE EXCEPTION 'Unknown expense category "%"', v_cat; END IF;
      INSERT INTO pnl_tracker.monthly_expense_lines (monthly_pnl_id, category_id, amount)
      VALUES (v_pnl, v_cat_id, COALESCE(NULLIF(v_amt, '')::numeric, 0));
    END LOOP;

    v_saved := v_saved || to_char(v_month, 'YYYY-MM');
  END LOOP;

  RETURN jsonb_build_object('saved', to_jsonb(v_saved));
END;
$$;

REVOKE ALL ON FUNCTION public.pnl_monthly(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pnl_expense_categories() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pnl_import(jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pnl_monthly(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.pnl_expense_categories() TO service_role;
GRANT EXECUTE ON FUNCTION public.pnl_import(jsonb, text) TO service_role;
