"""
build_dimensions.py — Staging Dimension Refresh
==============================================
Reads from raw.* tables and upserts into staging.* dimension tables.
Uses psycopg2 for all DB operations.

Run by run_pipeline.py after raw ingestion completes.
"""

import os
import sys
import socket
import pandas as pd
from pathlib import Path
from urllib.parse import urlparse
from dotenv import load_dotenv
from psycopg2.extras import execute_values

script_dir = Path(__file__).resolve().parent
pipeline_root = script_dir.parent

load_dotenv(pipeline_root / ".env")

# Prefer pooler for GitHub Actions IPv4 compatibility
DB_URL = os.environ.get("SUPABASE_DB_URL_POOLER") or os.environ.get("SUPABASE_DB_URL")
if not DB_URL:
    raise SystemExit("Error: SUPABASE_DB_URL_POOLER / SUPABASE_DB_URL not set in environment")


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


def pg_insert_batch(conn, sql, rows, page_size=1000):
    """Batch insert using execute_values."""
    cur = conn.cursor()
    execute_values(cur, sql, rows, page_size=page_size)
    conn.commit()
    cur.close()


def pg_truncate_and_insert(conn, table, cols, rows):
    """Truncate table then batch insert."""
    cur = conn.cursor()
    cur.execute(f'TRUNCATE TABLE {table} RESTART IDENTITY CASCADE')
    conn.commit()
    cur.close()
    if not rows:
        return
    col_sql = ", ".join(cols)
    sql = f"INSERT INTO {table} ({col_sql}) VALUES %s"
    pg_insert_batch(conn, sql, rows)


def clean_str(val, casing=None):
    if val is None or pd.isna(val):
        return None
    s = str(val).strip()
    if s in ("", "nan", "None", "<NA>"):
        return None
    if casing == "title":
        return s.title()
    elif casing == "upper":
        return s.upper()
    elif casing == "lower":
        return s.lower()
    return s


def build_dimensions():
    print("Building staging dimensions...")
    conn = get_pg_conn()

    # ─── Fetch raw sales ─────────────────────────────────────────────────
    print("Fetching raw.sales...")
    # This step still needs the full source to rebuild dimensions, but using
    # OFFSET made later pages progressively slower as raw.sales grew.
    all_raw = pg_fetch_all(conn, 'SELECT * FROM raw.sales ORDER BY id')

    print(f"  Retrieved {len(all_raw)} raw sales rows.")
    if not all_raw:
        print("  No raw sales rows. Skipping dimension build.")
        conn.close()
        return

    df = pd.DataFrame(all_raw)

    # ─── dim_store ─────────────────────────────────────────────────────
    print("Building dim_store...")
    store_df = df[
        df.get("Store Number", pd.Series()).notna() &
        ~df.get("Store Number", pd.Series()).isin(["Total", "Grand Total"])
    ]
    store_cols = ["Store Number", "Store Name", "SAP Code", "Region", "State Name"]
    existing_cols = [c for c in store_cols if c in df.columns]
    stores_unique = store_df[existing_cols].drop_duplicates(subset=["Store Number"])

    store_records = []
    for _, r in stores_unique.iterrows():
        store_records.append((
            clean_str(r.get("Store Name"), "title"),
            clean_str(r.get("Store Number")),
            clean_str(r.get("SAP Code")),
            None,  # city
            clean_str(r.get("State Name"), "upper"),
            clean_str(r.get("Region"), "title"),
            None,  # asm
            clean_str(r.get("Store Name"), "title"),  # footfall_location_name
        ))
    print(f"  {len(store_records)} unique stores.")
    if store_records:
        pg_truncate_and_insert(
            conn, "staging.dim_store",
            ["site_name", "site_short_name", "site_code", "city", "state",
             "region", "asm", "footfall_location_name"],
            store_records
        )

    # ─── dim_salesperson ───────────────────────────────────────────────
    print("Building dim_salesperson...")
    sm_col = "Salesman" if "Salesman" in df.columns else None
    if sm_col:
        sp_df = df[df[sm_col].notna()]
        sp_unique = sp_df[sm_col].unique()
        sp_records = []
        for raw_name in sp_unique:
            cleaned = clean_str(str(raw_name).rstrip("."), "title")
            if cleaned:
                sp_records.append((raw_name, cleaned, None, "Active"))
        print(f"  {len(sp_records)} unique salespeople.")
        if sp_records:
            pg_truncate_and_insert(
                conn, "staging.dim_salesperson",
                ["salesperson_name_raw", "salesperson_name",
                 "salesperson_code", "status"],
                sp_records
            )

    # ─── dim_promotion ─────────────────────────────────────────────────
    print("Building dim_promotion...")
    promo_col = "Sales Promo Code" if "Sales Promo Code" in df.columns else None
    promo_desc_col = "Sales Promo Description" if "Sales Promo Description" in df.columns else None
    promo_records = [(0, "NO_PROMO", "No Promotion")]
    if promo_col:
        promo_df = df[df[promo_col].notna()]
        if promo_desc_col:
            promo_unique = promo_df[[promo_col, promo_desc_col]].drop_duplicates(subset=[promo_col])
        else:
            promo_unique = promo_df[[promo_col]].drop_duplicates(subset=[promo_col])
        for _, r in promo_unique.iterrows():
            code = clean_str(r[promo_col])
            if code and code != "NO_PROMO":
                desc = clean_str(r[promo_desc_col], "title") if promo_desc_col else code
            promo_records.append((len(promo_records), code, desc))
    print(f"  {len(promo_records)} unique promotions.")
    if promo_records:
        pg_truncate_and_insert(
            conn, "staging.dim_promotion",
            ["promo_key", "promo_code", "promo_description"],
            promo_records
        )

    # ─── dim_product ───────────────────────────────────────────────────
    print("Building dim_product...")
    bc_col = "Bar Code" if "Bar Code" in df.columns else None
    if bc_col:
        prod_df = df[df[bc_col].notna()]
        prod_cols = ["Bar Code", "Item Description", "Brand", "Section",
                     "Category", "HSN Code", "MRP"]
        prod_cols = [c for c in prod_cols if c in df.columns]
        products_unique = prod_df[prod_cols].drop_duplicates(subset=[bc_col])

        prod_records = []
        for _, r in products_unique.iterrows():
            mrp_val = r.get("MRP")
            try:
                mrp_num = float(mrp_val) if mrp_val and not pd.isna(mrp_val) else None
            except (ValueError, TypeError):
                mrp_num = None

            prod_records.append((
                clean_str(r.get("Bar Code")),
                clean_str(r.get("Item Description")),
                clean_str(r.get("Item Description")),  # short_name
                clean_str(r.get("Section"), "title"),
                clean_str(r.get("Category"), "title"),
                clean_str(r.get("Brand"), "title"),
                None, None, None, None, None,  # category_1..5, color
                clean_str(r.get("HSN Code")),
                mrp_num,
                None, None,  # vendor_name, partner_name
            ))
        print(f"  {len(prod_records)} unique products.")
        if prod_records:
            pg_truncate_and_insert(
                conn, "staging.dim_product",
                ["barcode", "article_name", "short_name", "section",
                 "department", "division", "category_1", "category_2",
                 "category_4", "category_5", "color", "hsn_code", "mrp",
                 "vendor_name", "partner_name"],
                prod_records
            )

    conn.close()
    print("Staging dimensions built successfully!")


if __name__ == "__main__":
    build_dimensions()
