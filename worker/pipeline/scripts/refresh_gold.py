"""
refresh_gold.py — Gold Layer Refresh
===================================
Reads from raw.* and staging.* tables, aggregates, and writes to gold.* tables.
Uses psycopg2 for all DB operations.
"""

import os
import sys
import socket
import pandas as pd
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse
from dotenv import load_dotenv
from psycopg2.extras import execute_values
try:
    from scripts.sales_snapshot import select_authoritative_sales_rows
except ModuleNotFoundError:
    from sales_snapshot import select_authoritative_sales_rows

script_dir = Path(__file__).resolve().parent
pipeline_root = script_dir.parent

load_dotenv(pipeline_root / ".env")

# Prefer pooler for GitHub Actions IPv4 compatibility
DB_URL = os.environ.get("SUPABASE_DB_URL_POOLER") or os.environ.get("SUPABASE_DB_URL")
if not DB_URL:
    raise SystemExit("Error: SUPABASE_DB_URL_POOLER / SUPABASE_DB_URL not set")


def get_pg_conn():
    """Connect with IPv4-only DNS to bypass GitHub Actions IPv6 issues."""
    import psycopg2
    parsed = urlparse(DB_URL)
    hostname = parsed.hostname
    port = parsed.port or 5432

    try:
        ipv4 = socket.gethostbyname(hostname)
    except socket.gaierror as e:
        raise RuntimeError(f"DNS resolution failed for {hostname}: {e}") from e

    return psycopg2.connect(
        host=hostname,
        hostaddr=ipv4,
        port=port,
        user=parsed.username,
        password=parsed.password,
        dbname=parsed.path.lstrip("/"),
        connect_timeout=30,
    )


def pg_fetch_all(conn, query, params=None):
    """Run SELECT, return list of dicts."""
    cur = conn.cursor()
    cur.execute(query, params)
    cols = [d[0] for d in cur.description]
    rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    cur.close()
    return rows


def pg_truncate(conn, table):
    """Truncate a table."""
    cur = conn.cursor()
    cur.execute(f'TRUNCATE TABLE {table} RESTART IDENTITY CASCADE')
    conn.commit()
    cur.close()


def pg_insert_batch(conn, sql, rows, page_size=500):
    if not rows:
        return
    cur = conn.cursor()
    execute_values(cur, sql, rows, page_size=page_size)
    conn.commit()
    cur.close()


def parse_num(val):
    if val is None or pd.isna(val):
        return 0.0
    try:
        s = str(val).replace(",", "").strip()
        return float(s) if s and s != "-" else 0.0
    except ValueError:
        return 0.0


def parse_date_key(date_str):
    if not date_str or pd.isna(date_str):
        return None, None
    s = str(date_str).strip()
    for fmt in ("%d-%m-%Y", "%Y-%m-%d", "%d/%m/%Y", "%Y/%m/%d"):
        try:
            dt = datetime.strptime(s.split()[0], fmt)
            date_key = int(dt.strftime("%Y%m%d"))
            full_date = dt.strftime("%Y-%m-%d")
            return date_key, full_date
        except ValueError:
            continue
    return None, None


def refresh_gold():
    print("Refreshing Gold layer...")
    conn = get_pg_conn()

    # ─── 1. Fetch raw.sales ─────────────────────────────────────────────
    print("Fetching raw.sales...")
    sales_rows = pg_fetch_all(
        conn,
        'SELECT * FROM raw.sales '
        'WHERE "Store Number" IS NOT NULL AND "Store Number" NOT IN (\'Total\', \'Grand Total\')'
    )
    raw_count = len(sales_rows)
    sales_rows = select_authoritative_sales_rows(sales_rows)
    print(f"  Found {raw_count} raw sales rows; using {len(sales_rows)} authoritative rows after snapshot deduplication.")

    if sales_rows:
        df = pd.DataFrame(sales_rows)

        # Build row-level records
        row_records = []
        for row in sales_rows:
            d_key, f_date = parse_date_key(row.get("Bill Date"))
            if not d_key:
                continue

            # NSV = Taxable Amount — this is the final sales amount per business rules.
            # Do NOT use "Value" (gross amount); Taxable Amount is the net/taxable figure.
            nsv = parse_num(row.get("Taxable Amount"))
            qty = parse_num(row.get("Qty"))
            mrp_unit = parse_num(row.get("MRP"))
            mrp_total = mrp_unit * abs(qty) if mrp_unit > 0 else 0.0

            row_records.append({
                "full_date": f_date,
                "date_key": d_key,
                "site_short_name": str(row.get("Store Number", "R1157")).strip(),
                "store_name": str(row.get("Store Name", "Reebok Uppal")).strip() or "Reebok Uppal",
                "division": str(row.get("Brand") or "Reebok").strip().title(),
                "section": str(row.get("Section") or "Apparel").strip().title(),
                "department": str(row.get("Category") or "General").strip().title(),
                "selling_amount": nsv,
                "mrp_value": mrp_total,
                "quantity": qty,
                "bill_no": str(row.get("Bill No.") or "").strip(),
            })

        if row_records:
            df_rows = pd.DataFrame(row_records)

            # ── 1a. Summary: store × date ─────────────────────────────
            grp = df_rows.groupby(["full_date", "date_key", "site_short_name", "store_name"])
            summary = []
            for (f_date, d_key, store_num, store_name), g in grp:
                summary.append((
                    f_date, int(d_key), store_num, store_name,
                    float(round(g["selling_amount"].sum(), 2)),
                    float(round(g["mrp_value"].sum(), 2)),
                    float(round(g["quantity"].sum(), 2)),
                    int(g["bill_no"].nunique()),
                ))

            print(f"  Truncating gold.fact_master_dashboard ({len(summary)} records)...")
            pg_truncate(conn, "gold.fact_master_dashboard")
            pg_insert_batch(conn,
                "INSERT INTO gold.fact_master_dashboard "
                "(full_date, date_key, site_short_name, store_name, selling_amount, "
                "mrp_value, quantity, bills) VALUES %s",
                summary
            )
            print("  ✓ fact_master_dashboard refreshed")

            # ── 1b. Granular: store × date × division × section × dept ─
            grp2 = df_rows.groupby(
                ["full_date", "date_key", "site_short_name", "store_name",
                 "division", "section", "department"]
            )
            granular = []
            for (f_date, d_key, store_num, store_name, div, sec, dept), g in grp2:
                granular.append((
                    f_date, int(d_key), store_num, store_name, div, sec, dept,
                    float(round(g["selling_amount"].sum(), 2)),
                    float(round(g["mrp_value"].sum(), 2)),
                    float(round(g["quantity"].sum(), 2)),
                ))

            print(f"  Truncating gold.fact_master_dashboard_granular ({len(granular)} records)...")
            pg_truncate(conn, "gold.fact_master_dashboard_granular")
            pg_insert_batch(conn,
                "INSERT INTO gold.fact_master_dashboard_granular "
                "(full_date, date_key, site_short_name, store_name, division, section, "
                "department, selling_amount, mrp_value, quantity) VALUES %s",
                granular
            )
            print("  ✓ fact_master_dashboard_granular refreshed")

    # ─── 2. Fetch raw.account_dsr → gold.fact_master_dashboard_payments ─
    print("Fetching raw.account_dsr...")
    dsr_rows = pg_fetch_all(conn, 'SELECT * FROM raw.account_dsr')
    print(f"  Found {len(dsr_rows)} DSR rows.")

    if dsr_rows:
        payment_records = []
        for row in dsr_rows:
            d_key, f_date = parse_date_key(row.get("Date"))
            if not d_key:
                continue

            store_num = str(row.get("Store Number") or "R1157").strip()
            upi = parse_num(row.get("UPI Amount"))
            cash = parse_num(row.get("Cash Amount"))
            card = parse_num(row.get("Card Amount"))
            other = parse_num(row.get("Other Amount"))
            tot = parse_num(row.get("Total Sales"))
            if tot <= 0:
                tot = upi + cash + card + other

            payment_records.append((
                f_date, d_key, store_num,
                tot,
                int(parse_num(row.get("Total Bills")) or 1),
                upi,
                int(parse_num(row.get("UPI Bills")) or (1 if upi > 0 else 0)),
                cash,
                int(parse_num(row.get("Cash Bills")) or (1 if cash > 0 else 0)),
                card,
                int(parse_num(row.get("Card Bills")) or (1 if card > 0 else 0)),
                other,
                int(parse_num(row.get("Other Bills")) or (1 if other > 0 else 0)),
            ))

        if payment_records:
            print(f"  Truncating gold.fact_master_dashboard_payments ({len(payment_records)} records)...")
            pg_truncate(conn, "gold.fact_master_dashboard_payments")
            pg_insert_batch(conn,
                "INSERT INTO gold.fact_master_dashboard_payments "
                "(full_date, date_key, site_short_name, total_sales, total_bills, "
                "upi_amount, upi_bills, cash_amount, cash_bills, "
                "card_amount, card_bills, other_amount, other_bills) VALUES %s",
                payment_records
            )
            print("  ✓ fact_master_dashboard_payments refreshed")

    conn.close()
    print("\n[OK] Gold layer refreshed successfully!")


if __name__ == "__main__":
    refresh_gold()
