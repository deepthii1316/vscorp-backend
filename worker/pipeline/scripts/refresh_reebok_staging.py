"""
refresh_reebok_staging.py — Uppal Reebok Staging Refresh
=========================================================
Reads raw.sales (cleaned the same way refresh_reebok.py cleans it — carry bags
excluded, via fetch_reebok_rows()) and loads it into the existing star-schema
staging.fact_sales, joined to staging.dim_product / dim_store / dim_salesperson
/ dim_date (built by build_dimensions.py, which now resolves dim_product's
division/article_type/footwear_type correctly for Reebok — see
build_dimensions.py and the 2026-09-22 migration).

MUST run after build_dimensions() in the same pipeline run: it needs the
barcode -> product_key / store number -> store_key maps that step builds.

Full rebuild every run (TRUNCATE + INSERT) — same convention as
gold.reebok_daily_metrics: this is single-store data, small enough that
incremental refresh isn't worth the complexity. (staging.fact_sales is also
already emptied as a side effect of build_dimensions()'s CASCADE truncate of
dim_product/dim_store, since fact_sales has FKs into them — the TRUNCATE here
is just belt-and-braces for standalone runs.)
"""

import sys
from psycopg2.extras import execute_values

try:
    from scripts.refresh_reebok import get_pg_conn, pg_fetch_all, fetch_reebok_rows, parse_num, parse_date, UPPAL_STORE
except ModuleNotFoundError:
    from refresh_reebok import get_pg_conn, pg_fetch_all, fetch_reebok_rows, parse_num, parse_date, UPPAL_STORE

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

INSERT_SQL = """
INSERT INTO staging.fact_sales (
    date_key, product_key, store_key, salesperson_key,
    bill_no, bill_datetime, sales_type,
    quantity, sale_mrp, selling_amount, tax_amount, tax_percent,
    taxable_amount, discount_amount, discount_derived
) VALUES %s
"""


def refresh_reebok_staging():
    print("Refreshing staging.fact_sales for Uppal Reebok...")
    conn = get_pg_conn()

    product_key_by_barcode = {
        r["barcode"]: r["product_key"]
        for r in pg_fetch_all(conn, "SELECT barcode, product_key FROM staging.dim_product")
    }
    store_key_by_number = {
        r["site_short_name"]: r["store_key"]
        for r in pg_fetch_all(conn, "SELECT site_short_name, store_key FROM staging.dim_store")
    }
    salesperson_key_by_raw = {
        r["salesperson_name_raw"]: r["salesperson_key"]
        for r in pg_fetch_all(conn, "SELECT salesperson_name_raw, salesperson_key FROM staging.dim_salesperson")
    }
    store_key = store_key_by_number.get(UPPAL_STORE)
    if store_key is None:
        raise SystemExit(
            f"staging.dim_store has no row for {UPPAL_STORE!r} — run build_dimensions() first."
        )

    raw_rows = fetch_reebok_rows(conn)
    print(f"  Fetched {len(raw_rows)} cleaned raw rows for {UPPAL_STORE}.")

    rows = []
    skipped_no_date = 0
    skipped_no_product = set()
    for r in raw_rows:
        d = parse_date(r.get("bill_date"))
        if d is None:
            skipped_no_date += 1
            continue
        barcode = r.get("barcode")
        product_key = product_key_by_barcode.get(barcode)
        if product_key is None:
            skipped_no_product.add(barcode)
            continue
        qty = parse_num(r.get("qty_raw"))
        mrp_unit = parse_num(r.get("mrp_raw"))
        nsv = round(parse_num(r.get("tax_raw")), 2)
        tax_amount = round(parse_num(r.get("cgst_raw")) + parse_num(r.get("sgst_raw")) + parse_num(r.get("igst_raw")), 2)
        rows.append((
            int(d.strftime("%Y%m%d")), product_key, store_key,
            salesperson_key_by_raw.get(r.get("salesman")),
            r.get("bill_no"), r.get("bill_date"), None,          # sales_type: not tracked for Reebok
            round(qty, 2), round(mrp_unit, 2), nsv, tax_amount, None,
            nsv, None, None,                                     # discount not tracked per-line (see refresh_reebok.py docstring)
        ))
    if skipped_no_date:
        print(f"  Skipped {skipped_no_date} row(s) with an unparseable Bill Date.")
    if skipped_no_product:
        print(f"  [WARN] {len(skipped_no_product)} barcode(s) not found in staging.dim_product, skipped: "
              + ", ".join(sorted(str(b) for b in skipped_no_product)[:20]))

    cur = conn.cursor()
    cur.execute("TRUNCATE TABLE staging.fact_sales RESTART IDENTITY")
    conn.commit()
    cur.close()

    if rows:
        cur = conn.cursor()
        execute_values(cur, INSERT_SQL, rows, page_size=1000)
        conn.commit()
        cur.close()

    conn.close()
    print(f"  [OK] staging.fact_sales refreshed — {len(rows)} rows.")


if __name__ == "__main__":
    refresh_reebok_staging()
