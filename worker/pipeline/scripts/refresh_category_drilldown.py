"""
refresh_category_drilldown.py — Uppal Reebok Category Drill-down gold refresh
==============================================================================
Aggregates staging.fact_sales (joined to dim_product/dim_store/dim_date) into
gold.reebok_category_drilldown, in pure SQL — no Python-side aggregation,
unlike the older Reebok gold tables. Must run AFTER refresh_reebok_staging.

Feeds the Master Dashboard's Category Drill-down tab:
  - Category drill-down: Division -> Section -> Article Type
    (rows WHERE footwear_type = '')
  - Footwear -- by Department: Open/Closed -> Department -> Section
    (rows WHERE division = 'footwear')
Both read from the same table; the frontend groups client-side (see
frontend/src/lib/categoryDrilldownShared.js), same "one generic tree" approach
used for the equivalent VS Corp / Skechers tables.
"""

import sys

try:
    from scripts.refresh_reebok import get_pg_conn, UPPAL_STORE
except ModuleNotFoundError:
    from refresh_reebok import get_pg_conn, UPPAL_STORE

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

REFRESH_SQL = """
INSERT INTO gold.reebok_category_drilldown (
    full_date, division, department, section, article_type, footwear_type, qty, mrp_value, nsv
)
SELECT
    d.full_date,
    p.division,
    coalesce(p.department, ''),
    coalesce(p.section, ''),
    coalesce(p.article_type, ''),
    coalesce(p.footwear_type, ''),
    sum(f.quantity),
    sum(abs(f.sale_mrp) * f.quantity),
    sum(f.taxable_amount)
FROM staging.fact_sales f
JOIN staging.dim_date d ON d.date_key = f.date_key
JOIN staging.dim_product p ON p.product_key = f.product_key
JOIN staging.dim_store s ON s.store_key = f.store_key
WHERE s.site_short_name = %s
GROUP BY d.full_date, p.division, coalesce(p.department, ''), coalesce(p.section, ''),
         coalesce(p.article_type, ''), coalesce(p.footwear_type, '')
"""


def refresh_category_drilldown():
    print("Refreshing gold.reebok_category_drilldown...")
    conn = get_pg_conn()
    cur = conn.cursor()
    cur.execute("TRUNCATE TABLE gold.reebok_category_drilldown")
    cur.execute(REFRESH_SQL, (UPPAL_STORE,))
    count = cur.rowcount
    conn.commit()
    cur.close()
    conn.close()
    print(f"  [OK] gold.reebok_category_drilldown refreshed — {count} rows.")


if __name__ == "__main__":
    refresh_category_drilldown()
