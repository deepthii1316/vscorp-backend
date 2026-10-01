"""
refresh_stock.py — staging.fact_stock from raw.inventory snapshots
==================================================================
MUST run after build_dimensions() (which TRUNCATEs dim_product/dim_store with CASCADE, emptying
fact_stock) — this step re-adds stock-only products and rebuilds every snapshot.

Join key: EAN. raw.inventory."Bar Code" holds the EAN (see ingest_file.INVENTORY_COLUMNS), and
staging.dim_product.barcode is the sales "Bar Code", which is also the EAN. A product that is in
stock but has never sold is added to dim_product here, with its division resolved by the same
resolve_division() the sales KPIs use (imported, not reimplemented), and department/section
title-cased the way build_dimensions.py does, so stock-only and sold products roll up into the
same Division > Department > Section tree. Attributes of a product that has sold keep their
sales-derived values; stock only fills style_code / size / color where sales left them empty.

Snapshots: one per "Stock Date" (the day the report describes). If two files describe the same
day, the most recently uploaded one wins — never sum two files for one day.
"""

import os
import socket
from pathlib import Path
from urllib.parse import urlparse

import psycopg2
from dotenv import load_dotenv
from psycopg2.extras import execute_values

try:
    from scripts.refresh_reebok import resolve_division
    from scripts.build_dimensions import clean_str
except ModuleNotFoundError:
    from refresh_reebok import resolve_division
    from build_dimensions import clean_str

script_dir = Path(__file__).resolve().parent
pipeline_root = script_dir.parent
load_dotenv(pipeline_root / ".env")
DB_URL = os.environ.get("SUPABASE_DB_URL_POOLER") or os.environ.get("SUPABASE_DB_URL")


def get_pg_conn():
    parsed = urlparse(DB_URL)
    hostname = parsed.hostname
    ipv4 = socket.gethostbyname(hostname)
    return psycopg2.connect(
        host=hostname,
        hostaddr=ipv4,
        port=parsed.port or 5432,
        user=parsed.username,
        password=parsed.password,
        dbname=parsed.path.lstrip("/"),
        connect_timeout=30,
    )


# Rows of the snapshot files in use: latest upload per Stock Date, EAN present.
CURRENT_ROWS_SQL = """
    WITH files AS (
        SELECT DISTINCT ON ("Stock Date") upload_audit_id
        FROM raw.inventory
        WHERE "Stock Date" IS NOT NULL AND upload_audit_id IS NOT NULL
        ORDER BY "Stock Date", uploaded_at DESC
    )
    SELECT i.*
    FROM raw.inventory i
    JOIN files f ON f.upload_audit_id = i.upload_audit_id
    WHERE NULLIF(TRIM(i."Bar Code"), '') IS NOT NULL
"""

NUM = "NULLIF(regexp_replace(COALESCE({}, ''), '[^0-9.-]', '', 'g'), '')::numeric"


def _upsert_stock_products(cur):
    """Add stock-only EANs to dim_product; fill style/size/color gaps on sold ones."""
    cur.execute(f"""
        SELECT DISTINCT ON (TRIM(i."Bar Code"))
            TRIM(i."Bar Code"), i."Item Description", i."Section", i."Category",
            i."Item Division", i."Class Name", NULL AS hsn, i."MRP",
            i."Style Code", i."Size", i."Color"
        FROM ({CURRENT_ROWS_SQL}) i
        ORDER BY TRIM(i."Bar Code"), i."Stock Date" DESC
    """)
    records = []
    for barcode, item, section, department, item_div, class_name, hsn, mrp, style, size, color in cur.fetchall():
        class_name = clean_str(class_name)
        division = resolve_division(clean_str(item_div), class_name)
        footwear_type = None
        if division == "footwear":
            footwear_type = "Closed" if str(class_name or "").strip().lower() == "shoes" else "Open"
        try:
            mrp_num = float(str(mrp).replace(",", "")) if mrp else None
        except ValueError:
            mrp_num = None
        records.append((
            barcode, clean_str(item), clean_str(item),
            clean_str(section, "title"), clean_str(department, "title"), division,
            hsn, mrp_num, class_name, footwear_type,
            clean_str(style), clean_str(size), clean_str(color),
        ))
    if not records:
        return 0
    execute_values(cur, """
        INSERT INTO staging.dim_product
            (barcode, article_name, short_name, section, department, division,
             hsn_code, mrp, article_type, footwear_type, style_code, size, color)
        VALUES %s
        ON CONFLICT (barcode) DO UPDATE SET
            style_code = COALESCE(staging.dim_product.style_code, EXCLUDED.style_code),
            size       = COALESCE(staging.dim_product.size, EXCLUDED.size),
            color      = COALESCE(staging.dim_product.color, EXCLUDED.color),
            mrp        = COALESCE(staging.dim_product.mrp, EXCLUDED.mrp)
    """, records, page_size=1000)
    return len(records)


def refresh_stock():
    """Rebuild staging.fact_stock (every snapshot) with set-based SQL."""
    conn = get_pg_conn()
    cur = conn.cursor()
    try:
        cur.execute(f"SELECT count(*) FROM ({CURRENT_ROWS_SQL}) x")
        if not cur.fetchone()[0]:
            print("No inventory rows with a Stock Date and EAN to refresh.")
            return

        cur.execute(f"""
            INSERT INTO staging.dim_store (site_name, site_short_name)
            SELECT DISTINCT ON (TRIM("Store Number"))
                COALESCE(NULLIF(TRIM("Store Name"), ''), TRIM("Store Number")),
                TRIM("Store Number")
            FROM ({CURRENT_ROWS_SQL}) i
            WHERE NULLIF(TRIM("Store Number"), '') IS NOT NULL
            ORDER BY TRIM("Store Number"), uploaded_at DESC
            ON CONFLICT (site_short_name) DO NOTHING
        """)
        products = _upsert_stock_products(cur)

        cur.execute("TRUNCATE TABLE staging.fact_stock RESTART IDENTITY")
        cur.execute(f"""
            INSERT INTO staging.fact_stock
                (snapshot_date_key, product_key, store_key, stock_location, closing_total_qty,
                 last_received_rate, last_grn_date_key, mrp,
                 stock_mrp_value, stock_cost_value, stock_value_with_tax, inward_type)
            SELECT
                TO_CHAR(i."Stock Date"::date, 'YYYYMMDD')::integer,
                p.product_key,
                s.store_key,
                'STORE',
                SUM({NUM.format('i."Stock Qty"')}),
                MAX({NUM.format('i."Unit Cost"')}),
                MAX(TO_CHAR(NULLIF(i."Last Inwarded Date", '')::date, 'YYYYMMDD')::integer),
                MAX({NUM.format('i."MRP"')}),
                SUM({NUM.format('i."MRP Value"')}),
                SUM({NUM.format('i."Cost Value"')}),
                SUM({NUM.format('i."Stock Value"')}),
                MAX(i."Inward Type")
            FROM ({CURRENT_ROWS_SQL}) i
            JOIN staging.dim_product p ON p.barcode = TRIM(i."Bar Code")
            JOIN staging.dim_store s ON s.site_short_name = TRIM(i."Store Number")
            GROUP BY 1, 2, 3
        """)
        inserted = cur.rowcount
        conn.commit()
        print(f"  dim_product: {products} stock EAN(s) upserted.")
        print(f"Stock fact refreshed: {inserted} rows.")
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()


if __name__ == "__main__":
    refresh_stock()
