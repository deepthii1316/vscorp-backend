"""Refresh staging.fact_stock from raw.inventory snapshots."""

import os
import socket
from pathlib import Path
from urllib.parse import urlparse

import psycopg2
from dotenv import load_dotenv

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


def number(value):
    try:
        return float(str(value or "0").replace(",", "").strip() or 0)
    except (TypeError, ValueError):
        return 0.0


def legacy_refresh_stock():
    conn = get_pg_conn()
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT
                COALESCE(NULLIF(TRIM("Bar Code"), ''), NULLIF(TRIM("SAP Code"), ''),
                         NULLIF(TRIM("Item Description"), '')) AS barcode,
                "Item Description", "Brand", "Section", "Category", "MRP",
                "Store Number", "Store Name", "Stock Qty", "Stock Value", uploaded_at
            FROM raw.inventory
            WHERE COALESCE("Bar Code", "SAP Code", "Item Description") IS NOT NULL
        """)
        rows = cur.fetchall()
        if not rows:
            print("No inventory rows to refresh.")
            return

        for row in rows:
            barcode, item, brand, section, category, mrp, store_num, store_name, *_ = row
            cur.execute("""
                INSERT INTO staging.dim_store (site_name, site_short_name)
                VALUES (%s, %s)
                ON CONFLICT (site_short_name) DO UPDATE SET site_name = EXCLUDED.site_name
            """, (store_name or store_num, store_num or "R1157"))
            cur.execute("""
                INSERT INTO staging.dim_product
                    (barcode, article_name, short_name, section, department, division, mrp)
                VALUES (%s, %s, %s, %s, %s, %s,
                    NULLIF(regexp_replace(%s, '[^0-9.-]', '', 'g'), '')::numeric)
                ON CONFLICT (barcode) DO UPDATE SET
                    article_name = COALESCE(EXCLUDED.article_name, staging.dim_product.article_name)
            """, (barcode, item, item, section, category, brand, str(mrp or "").replace(",", "")))

        cur.execute("TRUNCATE TABLE staging.fact_stock RESTART IDENTITY")
        cur.execute("""
            INSERT INTO staging.fact_stock
                (snapshot_date_key, product_key, store_key, stock_location, closing_total_qty,
                 last_received_rate)
            SELECT
                TO_CHAR(i.uploaded_at::date, 'YYYYMMDD')::integer,
                p.product_key,
                s.store_key,
                i."Store Name",
                NULLIF(regexp_replace(i."Stock Qty", '[^0-9.-]', '', 'g'), '')::numeric,
                NULLIF(regexp_replace(i."Stock Value", '[^0-9.-]', '', 'g'), '')::numeric
            FROM raw.inventory i
            JOIN staging.dim_product p ON p.barcode = COALESCE(NULLIF(TRIM(i."Bar Code"), ''), NULLIF(TRIM(i."SAP Code"), ''), NULLIF(TRIM(i."Item Description"), ''))
            JOIN staging.dim_store s ON s.site_short_name = COALESCE(NULLIF(TRIM(i."Store Number"), ''), 'R1157')
        """)
        conn.commit()
        print(f"Stock fact refreshed: {cur.rowcount} rows.")
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()


def refresh_stock():
    """Refresh stock with set-based SQL, not two network statements per row."""
    conn = get_pg_conn()
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT EXISTS (
                SELECT 1 FROM raw.inventory
                WHERE COALESCE("Bar Code", "SAP Code", "Item Description") IS NOT NULL
            )
        """)
        if not cur.fetchone()[0]:
            print("No inventory rows to refresh.")
            return

        cur.execute("""
            INSERT INTO staging.dim_store (site_name, site_short_name)
            SELECT DISTINCT ON (COALESCE(NULLIF(TRIM("Store Number"), ''), 'R1157'))
                COALESCE(NULLIF(TRIM("Store Name"), ''), NULLIF(TRIM("Store Number"), ''), 'R1157'),
                COALESCE(NULLIF(TRIM("Store Number"), ''), 'R1157')
            FROM raw.inventory
            WHERE COALESCE("Bar Code", "SAP Code", "Item Description") IS NOT NULL
            ORDER BY COALESCE(NULLIF(TRIM("Store Number"), ''), 'R1157'), uploaded_at DESC
            ON CONFLICT (site_short_name) DO UPDATE
            SET site_name = EXCLUDED.site_name
        """)
        cur.execute("""
            INSERT INTO staging.dim_product
                (barcode, article_name, short_name, section, department, division, mrp)
            SELECT DISTINCT ON (barcode)
                barcode,
                "Item Description",
                "Item Description",
                "Section",
                "Category",
                "Brand",
                NULLIF(regexp_replace(COALESCE("MRP", ''), '[^0-9.-]', '', 'g'), '')::numeric
            FROM (
                SELECT
                    COALESCE(NULLIF(TRIM("Bar Code"), ''), NULLIF(TRIM("SAP Code"), ''),
                             NULLIF(TRIM("Item Description"), '')) AS barcode,
                    "Item Description", "Section", "Category", "Brand", "MRP", uploaded_at
                FROM raw.inventory
            ) inventory_rows
            WHERE barcode IS NOT NULL
            ORDER BY barcode, uploaded_at DESC
             ON CONFLICT (barcode) DO UPDATE SET
                article_name = COALESCE(EXCLUDED.article_name, staging.dim_product.article_name),
                short_name = COALESCE(EXCLUDED.short_name, staging.dim_product.short_name),
                mrp = COALESCE(EXCLUDED.mrp, staging.dim_product.mrp)
        """)
        cur.execute("TRUNCATE TABLE staging.fact_stock RESTART IDENTITY")
        cur.execute("""
            INSERT INTO staging.fact_stock
                (snapshot_date_key, product_key, store_key, stock_location, closing_total_qty,
                 last_received_rate)
            SELECT
                TO_CHAR(i.uploaded_at::date, 'YYYYMMDD')::integer,
                p.product_key,
                s.store_key,
                i."Store Name",
                NULLIF(regexp_replace(i."Stock Qty", '[^0-9.-]', '', 'g'), '')::numeric,
                NULLIF(regexp_replace(i."Stock Value", '[^0-9.-]', '', 'g'), '')::numeric
            FROM raw.inventory i
            JOIN staging.dim_product p ON p.barcode = COALESCE(
                NULLIF(TRIM(i."Bar Code"), ''), NULLIF(TRIM(i."SAP Code"), ''),
                NULLIF(TRIM(i."Item Description"), '')
            )
            JOIN staging.dim_store s ON s.site_short_name = COALESCE(
                NULLIF(TRIM(i."Store Number"), ''), 'R1157'
            )
        """)
        inserted = cur.rowcount
        conn.commit()
        print(f"Stock fact refreshed: {inserted} rows.")
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()


if __name__ == "__main__":
    refresh_stock()
