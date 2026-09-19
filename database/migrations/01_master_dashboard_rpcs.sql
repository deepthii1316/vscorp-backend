-- =============================================================
-- Reebok Master Dashboard — PostgreSQL RPC Aggregation Layer
-- (Updated: reads from gold schema instead of staging)
-- =============================================================

-- 1. MASTER DASHBOARD SUMMARY RPC
CREATE OR REPLACE FUNCTION public.get_master_dashboard_summary(
    p_start_date date DEFAULT '2026-01-01',
    p_end_date date DEFAULT '2026-12-31',
    p_stores text[] DEFAULT NULL,
    p_divisions text[] DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = gold, public
AS $$
DECLARE
    v_start_key integer;
    v_end_key integer;
    v_total_rsv numeric := 0;
    v_total_mrp numeric := 0;
    v_total_qty numeric := 0;
    v_total_bills integer := 0;
    v_days_count integer := 1;
    v_avg_per_day numeric := 0;
    v_md_pct numeric := 0;
    v_atv numeric := 0;
    v_daily_trend json;
    v_division_split json;
    v_top_stores json;
    v_store_performance json;
BEGIN
    v_start_key := to_char(p_start_date, 'YYYYMMDD')::integer;
    v_end_key := to_char(p_end_date, 'YYYYMMDD')::integer;
    v_days_count := GREATEST(1, (p_end_date - p_start_date + 1));

    -- Top-line Aggregation from gold.fact_master_dashboard
    SELECT
        COALESCE(SUM(selling_amount), 0),
        COALESCE(SUM(mrp_value), 0),
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(bills), 0)
    INTO v_total_rsv, v_total_mrp, v_total_qty, v_total_bills
    FROM gold.fact_master_dashboard
    WHERE full_date BETWEEN p_start_date AND p_end_date
      AND (p_stores IS NULL OR site_short_name = ANY(p_stores));

    v_avg_per_day := ROUND(v_total_rsv / v_days_count, 2);
    IF v_total_mrp > 0 THEN
        v_md_pct := ROUND(((v_total_mrp - v_total_rsv) / v_total_mrp) * 100, 2);
    END IF;
    IF v_total_bills > 0 THEN
        v_atv := ROUND(v_total_rsv / v_total_bills, 2);
    END IF;

    -- Daily Trend Timeseries
    SELECT json_agg(t) INTO v_daily_trend
    FROM (
        SELECT
            full_date::text as date,
            to_char(full_date, 'MM-DD') as label,
            COALESCE(SUM(selling_amount), 0) as rsv,
            COALESCE(SUM(quantity), 0) as qty,
            COALESCE(SUM(bills), 0) as bills
        FROM gold.fact_master_dashboard
        WHERE full_date BETWEEN p_start_date AND p_end_date
          AND (p_stores IS NULL OR site_short_name = ANY(p_stores))
        GROUP BY full_date
        ORDER BY full_date ASC
    ) t;

    -- Division Split from gold.fact_master_dashboard_granular
    SELECT json_agg(d) INTO v_division_split
    FROM (
        SELECT
            division,
            COALESCE(SUM(selling_amount), 0) as rsv,
            COALESCE(SUM(quantity), 0) as qty
        FROM gold.fact_master_dashboard_granular
        WHERE full_date BETWEEN p_start_date AND p_end_date
          AND (p_stores IS NULL OR site_short_name = ANY(p_stores))
        GROUP BY division
    ) d;

    -- Top Stores by RSV
    SELECT json_agg(s) INTO v_top_stores
    FROM (
        SELECT
            COALESCE(store_name, site_short_name) as store_name,
            site_short_name,
            COALESCE(SUM(selling_amount), 0) as rsv,
            COALESCE(SUM(quantity), 0) as qty
        FROM gold.fact_master_dashboard
        WHERE full_date BETWEEN p_start_date AND p_end_date
        GROUP BY store_name, site_short_name
        ORDER BY rsv DESC
        LIMIT 10
    ) s;

    -- Store Performance Table
    SELECT json_agg(p) INTO v_store_performance
    FROM (
        SELECT
            COALESCE(store_name, site_short_name) as store_name,
            site_short_name,
            COALESCE(SUM(selling_amount), 0) as rsv,
            COALESCE(SUM(bills), 0) as bills,
            COALESCE(SUM(quantity), 0) as qty_sold,
            CASE WHEN SUM(mrp_value) > 0 THEN ROUND(((SUM(mrp_value) - SUM(selling_amount)) / SUM(mrp_value)) * 100, 2) ELSE 0 END as md_pct
        FROM gold.fact_master_dashboard
        WHERE full_date BETWEEN p_start_date AND p_end_date
        GROUP BY store_name, site_short_name
        ORDER BY rsv DESC
    ) p;

    RETURN json_build_object(
        'kpis', json_build_object(
            'rsv', v_total_rsv,
            'avgPerDay', v_avg_per_day,
            'mdPct', v_md_pct,
            'qtySold', v_total_qty,
            'bills', v_total_bills,
            'atv', v_atv,
            'daysCount', v_days_count
        ),
        'dailyTrend', COALESCE(v_daily_trend, '[]'::json),
        'divisionSplit', COALESCE(v_division_split, '[]'::json),
        'topStores', COALESCE(v_top_stores, '[]'::json),
        'storePerformance', COALESCE(v_store_performance, '[]'::json)
    );
END;
$$;


-- 2. ACCOUNT DSR PAYMENT MODE SPLIT RPC
CREATE OR REPLACE FUNCTION public.get_master_dashboard_payments(
    p_start_date date DEFAULT '2026-01-01',
    p_end_date date DEFAULT '2026-12-31',
    p_stores text[] DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = gold, public
AS $$
DECLARE
    v_total_sales numeric := 0;
    v_upi_amount numeric := 0;
    v_cash_amount numeric := 0;
    v_card_amount numeric := 0;
    v_other_amount numeric := 0;
    v_upi_pct numeric := 0;
    v_cash_pct numeric := 0;
    v_card_pct numeric := 0;
    v_other_pct numeric := 0;
    v_payment_trend json;
    v_store_payments json;
BEGIN
    SELECT
        COALESCE(SUM(total_sales), 0),
        COALESCE(SUM(upi_amount), 0),
        COALESCE(SUM(cash_amount), 0),
        COALESCE(SUM(card_amount), 0),
        COALESCE(SUM(other_amount), 0)
    INTO v_total_sales, v_upi_amount, v_cash_amount, v_card_amount, v_other_amount
    FROM gold.fact_master_dashboard_payments
    WHERE full_date BETWEEN p_start_date AND p_end_date
      AND (p_stores IS NULL OR site_short_name = ANY(p_stores));

    IF v_total_sales > 0 THEN
        v_upi_pct := ROUND((v_upi_amount / v_total_sales) * 100, 2);
        v_cash_pct := ROUND((v_cash_amount / v_total_sales) * 100, 2);
        v_card_pct := ROUND((v_card_amount / v_total_sales) * 100, 2);
        v_other_pct := ROUND((v_other_amount / v_total_sales) * 100, 2);
    END IF;

    -- Daily Payment Trend
    SELECT json_agg(t) INTO v_payment_trend
    FROM (
        SELECT
            full_date::text as date,
            COALESCE(SUM(upi_amount), 0) as upi,
            COALESCE(SUM(cash_amount), 0) as cash,
            COALESCE(SUM(card_amount), 0) as card,
            COALESCE(SUM(other_amount), 0) as other
        FROM gold.fact_master_dashboard_payments
        WHERE full_date BETWEEN p_start_date AND p_end_date
          AND (p_stores IS NULL OR site_short_name = ANY(p_stores))
        GROUP BY full_date
        ORDER BY full_date ASC
    ) t;

    -- Store Payment Breakdown
    SELECT json_agg(sp) INTO v_store_payments
    FROM (
        SELECT
            site_short_name as store_number,
            COALESCE(SUM(total_sales), 0) as total_sales,
            COALESCE(SUM(upi_amount), 0) as upi_amount,
            COALESCE(SUM(cash_amount), 0) as cash_amount,
            COALESCE(SUM(card_amount), 0) as card_amount,
            COALESCE(SUM(other_amount), 0) as other_amount
        FROM gold.fact_master_dashboard_payments
        WHERE full_date BETWEEN p_start_date AND p_end_date
        GROUP BY site_short_name
        ORDER BY total_sales DESC
    ) sp;

    RETURN json_build_object(
        'totals', json_build_object(
            'totalSales', v_total_sales,
            'upiAmount', v_upi_amount,
            'upiPct', v_upi_pct,
            'cashAmount', v_cash_amount,
            'cashPct', v_cash_pct,
            'cardAmount', v_card_amount,
            'cardPct', v_card_pct,
            'otherAmount', v_other_amount,
            'otherPct', v_other_pct
        ),
        'paymentTrend', COALESCE(v_payment_trend, '[]'::json),
        'storePayments', COALESCE(v_store_payments, '[]'::json)
    );
END;
$$;
