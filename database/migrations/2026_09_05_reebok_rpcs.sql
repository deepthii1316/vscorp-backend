-- =============================================================
-- Uppal Reebok — 4 Report RPCs
-- =============================================================
-- Source: gold.reebok_daily_metrics (populated by
-- pipeline/scripts/refresh_reebok.py).
--
-- All four RPCs are SECURITY DEFINER so the Next.js route can call
-- them without an explicit service-role grant. They read the gold
-- table only (no raw.sales exposure) and accept a single p_date.
--
-- They return a single JSON object containing both TODAY and MTD
-- rows for the requested date. The application layer unpacks this
-- for the HTML/Excel builders.
--
-- Hard rules:
--   * Numbers are returned as numeric — PostgREST will serialise as
--     a STRING, so the JS side must coerce with Number() / parseFloat.
--   * Target stays NULL until the manager confirms the formula. Do
--     NOT reverse-engineer the existing ₹45,161.
--   * Ratios are pre-computed in the gold table (recalculated from
--     summed numerators, not averaged).
-- =============================================================


-- ─── 1. rpt_reebok_daywise ──────────────────────────────────────────────────
-- Returns TODAY and MTD side-by-side for the requested date.
-- One row per period_type — caller pivots.
CREATE OR REPLACE FUNCTION public.rpt_reebok_daywise(p_date date)
RETURNS TABLE (
    period_type             text,
    full_date               date,
    nsv                     numeric,
    target                  numeric,
    achievement_pct         numeric,
    bills                   integer,
    qty_sold                numeric,
    atv                     numeric,
    upt                     numeric,
    asp                     numeric,
    fupt                    numeric,
    footwear_qty            numeric,
    footwear_nsv            numeric,
    apparel_qty             numeric,
    apparel_nsv             numeric,
    accessories_qty         numeric,
    accessories_nsv         numeric,
    socks_qty               numeric,
    socks_nsv               numeric,
    sfr                     numeric,
    afr                     numeric
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, gold, staging
AS $$
    SELECT
        m.period_type,
        m.full_date,
        m.nsv,
        m.target,
        m.achievement_pct,
        m.bills,
        m.qty_sold,
        m.atv,
        m.upt,
        m.asp,
        m.fupt,
        m.footwear_qty,
        m.footwear_nsv,
        m.apparel_qty,
        m.apparel_nsv,
        m.accessories_qty,
        m.accessories_nsv,
        m.socks_qty,
        m.socks_nsv,
        m.sfr,
        m.afr
    FROM gold.reebok_daily_metrics m
    WHERE m.full_date = p_date
      AND m.site_short_name = 'R1157'
      AND m.period_type IN ('today', 'mtd')
    ORDER BY m.period_type DESC;  -- 'today' first
$$;

GRANT EXECUTE ON FUNCTION public.rpt_reebok_daywise(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.rpt_reebok_daywise(date) FROM anon;


-- ─── 2. rpt_reebok_staffwise ───────────────────────────────────────────────
-- One row per (period_type, salesperson) for the 3 known associates.
-- The RPC unpacks the gold.staffwise JSONB into columns.
DROP FUNCTION IF EXISTS public.rpt_reebok_staffwise(date);
CREATE OR REPLACE FUNCTION public.rpt_reebok_staffwise(p_date date)
RETURNS TABLE (
    period_type         text,
    salesperson_name    text,
    role                text,
    qty                 numeric,
    nsv                 numeric,
    bills               integer,
    atv                 numeric,
    upt                 numeric,
    asp                 numeric,
    sfr                 numeric,
    afr                 numeric,
    footwear_qty        numeric,
    footwear_nsv        numeric,
    apparel_qty         numeric,
    apparel_nsv         numeric,
    accessories_qty     numeric,
    accessories_nsv     numeric
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, gold, staging
AS $$
    WITH metrics AS (
        SELECT period_type, staffwise
        FROM gold.reebok_daily_metrics
        WHERE full_date = p_date
          AND site_short_name = 'R1157'
          AND period_type IN ('today', 'mtd')
    ),
    expanded AS (
        SELECT
            m.period_type,
            k.key  AS salesperson_name,
            'Sales Associate'::text AS role,
            (k.value ->> 'qty')::numeric              AS qty,
            (k.value ->> 'nsv')::numeric              AS nsv,
            COALESCE((k.value ->> 'bills')::integer, 0) AS bills,
            (k.value ->> 'atv')::numeric              AS atv,
            (k.value ->> 'upt')::numeric              AS upt,
            (k.value ->> 'asp')::numeric              AS asp,
            (k.value ->> 'sfr')::numeric              AS sfr,
            (k.value ->> 'afr')::numeric              AS afr,
            (k.value ->> 'footwear_qty')::numeric     AS footwear_qty,
            (k.value ->> 'footwear_nsv')::numeric     AS footwear_nsv,
            (k.value ->> 'apparel_qty')::numeric      AS apparel_qty,
            (k.value ->> 'apparel_nsv')::numeric      AS apparel_nsv,
            (k.value ->> 'accessories_qty')::numeric  AS accessories_qty,
            (k.value ->> 'accessories_nsv')::numeric  AS accessories_nsv
        FROM metrics m,
             LATERAL jsonb_each(m.staffwise) AS k(key, value)
    )
    SELECT * FROM expanded
    ORDER BY period_type DESC, salesperson_name;
$$;

GRANT EXECUTE ON FUNCTION public.rpt_reebok_staffwise(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.rpt_reebok_staffwise(date) FROM anon;


-- ─── 3. rpt_reebok_category ────────────────────────────────────────────────
-- Returns Footwear / Apparel / Accessories rows for TODAY and MTD.
-- Unpacks division_breakdown JSONB into columns.
CREATE OR REPLACE FUNCTION public.rpt_reebok_category(p_date date)
RETURNS TABLE (
    period_type         text,
    category            text,
    qty                 numeric,
    nsv                 numeric
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, gold, staging
AS $$
    WITH metrics AS (
        SELECT period_type, division_breakdown
        FROM gold.reebok_daily_metrics
        WHERE full_date = p_date
          AND site_short_name = 'R1157'
          AND period_type IN ('today', 'mtd')
    ),
    expanded AS (
        SELECT
            m.period_type,
            k.key  AS category,
            (k.value ->> 'qty')::numeric  AS qty,
            (k.value ->> 'nsv')::numeric  AS nsv
        FROM metrics m,
             LATERAL jsonb_each(m.division_breakdown) AS k(key, value)
    )
    SELECT * FROM expanded
    ORDER BY period_type DESC, category;
$$;

GRANT EXECUTE ON FUNCTION public.rpt_reebok_category(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.rpt_reebok_category(date) FROM anon;


-- ─── 4. rpt_reebok_gender_division ─────────────────────────────────────────
-- Returns gender × division cross-tab for TODAY and MTD.
-- Unpacks gender_division JSONB (gender -> division -> {qty, nsv}).
CREATE OR REPLACE FUNCTION public.rpt_reebok_gender_division(p_date date)
RETURNS TABLE (
    period_type         text,
    gender              text,
    division            text,
    qty                 numeric,
    nsv                 numeric
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, gold, staging
AS $$
    WITH metrics AS (
        SELECT period_type, gender_division
        FROM gold.reebok_daily_metrics
        WHERE full_date = p_date
          AND site_short_name = 'R1157'
          AND period_type IN ('today', 'mtd')
    ),
    expanded AS (
        SELECT
            m.period_type,
            g.key  AS gender,
            d.key  AS division,
            (d.value ->> 'qty')::numeric  AS qty,
            (d.value ->> 'nsv')::numeric  AS nsv
        FROM metrics m,
             LATERAL jsonb_each(m.gender_division) AS g(key, value),
             LATERAL jsonb_each(g.value) AS d(key, value)
    )
    SELECT * FROM expanded
    ORDER BY period_type DESC, gender, division;
$$;

GRANT EXECUTE ON FUNCTION public.rpt_reebok_gender_division(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.rpt_reebok_gender_division(date) FROM anon;
