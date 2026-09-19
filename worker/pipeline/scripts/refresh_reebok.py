"""
refresh_reebok.py — Uppal Reebok Gold Layer Refresh
==================================================
Reads raw.sales for UPPAL REEBOK (Store Number = 'R1157'), aggregates
every required KPI, and upserts into gold.reebok_daily_metrics.

The gold table has one row per (full_date, period_type) where
period_type in ('today', 'mtd'). This script populates BOTH for every
date that has sales data, so all 4 reports can read from one table.

Business rules (per artifacts/docs/REEBOOK_KPI_DEFINITIONS.md):
  * NSV / RSV = SUM("Taxable Amount")
  * Bills = COUNT(DISTINCT "Bill No.")
  * Qty = SUM("Qty")
  * ATV = NSV / Bills
  * UPT = Qty / Bills
  * ASP = NSV / Qty
  * Footwear qty/nsv  = WHERE "Item Division" = 'FOOTWEAR'
  * Apparel qty/nsv   = WHERE "Item Division" = 'APPAREL'
  * Accessories qty/nsv = everything else (NULL division or non-FW/APP)
  * Socks qty = WHERE "Class Name" ILIKE '%sock%'
  * Men/Women/Unisex  = from "Section" field (RB MEN / RB WOMEN / RB UNISEX)
  * Ratios always recomputed from summed numerators/denominators.
  * Target = NULL (only the ₹45,161 value existed before; it was
    Claude-generated and the manager said it can change — we do not
    reverse-engineer. The approved ₹8L budget is applied at the report
    layer, not pre-baked into this gold table.)

Ratios (SFR/AFR/ATV/UPT/ASP/FUPT) are computed in SQL on summed values,
not averaged across rows.
"""

import os
import sys
import socket
import json
from pathlib import Path
from urllib.parse import urlparse
from datetime import datetime
from dotenv import load_dotenv
import psycopg2
from psycopg2.extras import execute_values
try:
    from scripts.sales_snapshot import select_authoritative_sales_rows
except ModuleNotFoundError:
    from sales_snapshot import select_authoritative_sales_rows

# Force UTF-8 on stdout for Windows
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

script_dir = Path(__file__).resolve().parent
pipeline_root = script_dir.parent

load_dotenv(pipeline_root / ".env")

# Prefer pooler for GitHub Actions IPv4 compatibility
DB_URL = os.environ.get("SUPABASE_DB_URL_POOLER") or os.environ.get("SUPABASE_DB_URL")
if not DB_URL:
    raise SystemExit("Error: SUPABASE_DB_URL_POOLER / SUPABASE_DB_URL not set in environment")

# The single store this report is for.
UPPAL_STORE = "R1157"


# ── DB helpers ────────────────────────────────────────────────────────────────

def get_pg_conn():
    """Connect with IPv4-only DNS to bypass GitHub Actions IPv6 issues."""
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
    cur = conn.cursor()
    cur.execute(query, params)
    cols = [d[0] for d in cur.description]
    rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    cur.close()
    return rows


def pg_execute(conn, query, params=None):
    """Execute a single statement, commit, close cursor."""
    cur = conn.cursor()
    cur.execute(query, params)
    conn.commit()
    cur.close()


def parse_num(val):
    """raw.sales columns are all text — convert carefully, NULL on empty."""
    if val is None:
        return 0.0
    s = str(val).strip().replace(",", "")
    if s in ("", "-", "nan", "None", "null", "n/a"):
        return 0.0
    try:
        return float(s)
    except ValueError:
        return 0.0


def parse_date(date_str):
    """raw.sales 'Bill Date' is dd-mm-YYYY text."""
    if not date_str:
        return None
    s = str(date_str).strip()
    for fmt in ("%d-%m-%Y", "%Y-%m-%d", "%d/%m/%Y", "%Y/%m/%d"):
        try:
            return datetime.strptime(s.split()[0], fmt).date()
        except ValueError:
            continue
    return None


def normalize_section(section):
    """
    Map raw Section values to (men, women, unisex) booleans.
    Reebok export uses 'RB MEN' / 'RB WOMEN' / 'RB UNISEX'.
    """
    if not section:
        return None
    s = str(section).strip().upper()
    if "MEN" in s and "WOMEN" not in s and "UNISEX" not in s:
        return "men"
    if "WOMEN" in s:
        return "women"
    if "UNISEX" in s:
        return "unisex"
    return None


def normalize_division(div):
    """
    Map raw 'Item Division' to footwear / apparel / accessories.
    Anything else (or NULL) is treated as accessories.
    """
    if not div:
        return "accessories"
    s = str(div).strip().upper()
    if s == "FOOTWEAR":
        return "footwear"
    if s == "APPAREL":
        return "apparel"
    return "accessories"


def is_socks(class_name):
    if not class_name:
        return False
    return "sock" in str(class_name).strip().lower()


# ── Aggregation queries ──────────────────────────────────────────────────────

def fetch_reebok_rows(conn):
    """Pull every sales row for UPPAL — but only real data rows, not footer/header."""
    raw_rows = pg_fetch_all(
        conn,
        """
        SELECT *
        FROM raw.sales
        WHERE "Store Number" = %s
          AND "Bill No." IS NOT NULL
          AND "Bill No." <> ''
          AND "Bill No." NOT ILIKE '%%total%%'
        ORDER BY "Bill Date", "Bill No."
        """,
        (UPPAL_STORE,),
    )
    selected = select_authoritative_sales_rows(raw_rows)
    return [
        {
            "bill_date": row.get("Bill Date"),
            "bill_no": row.get("Bill No."),
            "qty_raw": row.get("Qty"),
            "tax_raw": row.get("Taxable Amount"),
            "item_division": row.get("Item Division"),
            "section": row.get("Section"),
            "class_name": row.get("Class Name"),
            "salesman": row.get("Salesman"),
        }
        for row in selected
    ]


def aggregate_one_date(rows_for_date):
    """
    Compute every KPI for one (full_date, period_type) given a list of raw rows.
    Returns a dict matching the gold table columns.
    """
    if not rows_for_date:
        return None

    nsv = 0.0
    qty = 0.0
    bills = set()

    fw_qty = fw_nsv = 0.0
    app_qty = app_nsv = 0.0
    acc_qty = acc_nsv = 0.0
    socks_qty = socks_nsv = 0.0

    men_qty = women_qty = unisex_qty = 0.0
    men_nsv = women_nsv = unisex_nsv = 0.0

    division_breakdown = {}  # division -> {qty, nsv}
    staffwise = {}           # name -> {qty, nsv, footwear_qty, footwear_nsv, ...}
    staff_bills = {}         # name -> distinct bill numbers
    gender_division = {}     # gender -> {division -> {qty, nsv}}

    for r in rows_for_date:
        line_qty = parse_num(r.get("qty_raw"))
        line_nsv = parse_num(r.get("tax_raw"))
        bill_no = r.get("bill_no")
        if bill_no:
            bills.add(str(bill_no).strip())

        nsv += line_nsv
        qty += line_qty

        div = normalize_division(r.get("item_division"))
        sec = normalize_section(r.get("section"))
        cls = r.get("class_name")
        sm = str(r.get("salesman") or "Unknown").strip().upper()

        # Category buckets
        if div == "footwear":
            fw_qty += line_qty
            fw_nsv += line_nsv
        elif div == "apparel":
            app_qty += line_qty
            app_nsv += line_nsv
        else:
            acc_qty += line_qty
            acc_nsv += line_nsv

        # Socks (any division, but Class Name like '%Sock%')
        if is_socks(cls):
            socks_qty += line_qty
            socks_nsv += line_nsv

        # Gender
        if sec == "men":
            men_qty += line_qty
            men_nsv += line_nsv
        elif sec == "women":
            women_qty += line_qty
            women_nsv += line_nsv
        elif sec == "unisex":
            unisex_qty += line_qty
            unisex_nsv += line_nsv

        # Division breakdown
        d = division_breakdown.setdefault(div, {"qty": 0.0, "nsv": 0.0})
        d["qty"] += line_qty
        d["nsv"] += line_nsv

        # Staffwise — per-associate by division
        s = staffwise.setdefault(sm, {
            "qty": 0.0, "nsv": 0.0,
            "footwear_qty": 0.0, "footwear_nsv": 0.0,
            "apparel_qty": 0.0, "apparel_nsv": 0.0,
            "accessories_qty": 0.0, "accessories_nsv": 0.0,
        })
        s["qty"] += line_qty
        s["nsv"] += line_nsv
        if is_socks(cls):
            s["socks_qty"] = s.get("socks_qty", 0.0) + line_qty
        s[f"{div}_qty"] += line_qty
        s[f"{div}_nsv"] += line_nsv
        staff_bills.setdefault(sm, set())
        if bill_no:
            staff_bills[sm].add(str(bill_no).strip())

        # Gender × division
        if sec:
            gd = gender_division.setdefault(sec, {})
            gd_bucket = gd.setdefault(div, {"qty": 0.0, "nsv": 0.0})
            gd_bucket["qty"] += line_qty
            gd_bucket["nsv"] += line_nsv

    def safe_div(a, b):
        return (a / b) if b and b != 0 else None

    # Keep all known associates visible, including associates with no sales.
    for staff_name in ("BALRAJ GADDAM", "RAMBABU DHARAVATH", "ERRI SRIJA"):
        staffwise.setdefault(staff_name, {
            "qty": 0.0, "nsv": 0.0,
            "socks_qty": 0.0,
            "footwear_qty": 0.0, "footwear_nsv": 0.0,
            "apparel_qty": 0.0, "apparel_nsv": 0.0,
            "accessories_qty": 0.0, "accessories_nsv": 0.0,
        })

    # Round JSONB nested values to 2dp to avoid float artefacts downstream
    for d in division_breakdown.values():
        d["qty"] = round(d["qty"], 2)
        d["nsv"] = round(d["nsv"], 2)
    for staff_name, s in staffwise.items():
        bills_for_staff = len(staff_bills.get(staff_name, set()))
        s["bills"] = bills_for_staff
        s["atv"] = safe_div(s["nsv"], bills_for_staff)
        s["upt"] = safe_div(s["qty"], bills_for_staff)
        s["asp"] = safe_div(s["nsv"], s["qty"])
        s["sfr"] = safe_div(s.get("socks_qty", 0), s["footwear_qty"])
        s["afr"] = safe_div(s["apparel_qty"], s["footwear_qty"])
        for k in s:
            if isinstance(s[k], (int, float)):
                s[k] = round(s[k], 4 if k in ("upt", "sfr", "afr") else 2)
    for gd in gender_division.values():
        for d in gd.values():
            d["qty"] = round(d["qty"], 2)
            d["nsv"] = round(d["nsv"], 2)

    # Recalculate ratios from summed numerators/denominators.
    bills_count = len(bills)
    atv = safe_div(nsv, bills_count)
    upt = safe_div(qty, bills_count)
    asp = safe_div(nsv, qty)
    fupt = safe_div(fw_qty, bills_count)
    sfr = safe_div(socks_qty, fw_qty)
    afr = safe_div(app_qty, fw_qty)

    # The KPI definition requires today's total sales and quantity to be
    # allocated equally across the three named associates. Category values
    # remain tied to the salesperson on each source row.
    return {
        "nsv": round(nsv, 2),
        "target": None,  # see module docstring — no reverse-engineering
        "achievement_pct": None,
        "bills": bills_count,
        "qty_sold": round(qty, 2),
        "atv": round(atv, 2) if atv is not None else None,
        "upt": round(upt, 4) if upt is not None else None,
        "asp": round(asp, 2) if asp is not None else None,
        "fupt": round(fupt, 4) if fupt is not None else None,
        "footwear_qty": round(fw_qty, 2),
        "footwear_nsv": round(fw_nsv, 2),
        "apparel_qty": round(app_qty, 2),
        "apparel_nsv": round(app_nsv, 2),
        "accessories_qty": round(acc_qty, 2),
        "accessories_nsv": round(acc_nsv, 2),
        "socks_qty": round(socks_qty, 2),
        "socks_nsv": round(socks_nsv, 2),
        "sfr": round(sfr, 4) if sfr is not None else None,
        "afr": round(afr, 4) if afr is not None else None,
        "men_qty": round(men_qty, 2),
        "women_qty": round(women_qty, 2),
        "unisex_qty": round(unisex_qty, 2),
        "men_nsv": round(men_nsv, 2),
        "women_nsv": round(women_nsv, 2),
        "unisex_nsv": round(unisex_nsv, 2),
        "division_breakdown": json.dumps(division_breakdown),
        "gender_division": json.dumps(gender_division),
        "staffwise": json.dumps(staffwise),
    }


# ── MTD rollup helper ────────────────────────────────────────────────────────

def group_rows_by_date(all_rows):
    """Returns dict { date -> list_of_rows }."""
    out = {}
    for r in all_rows:
        d = parse_date(r.get("bill_date"))
        if d is None:
            continue
        out.setdefault(d, []).append(r)
    return out


def rows_up_to(rows_by_date, target_date):
    """Concat all rows where date <= target_date in the same month/year."""
    out = []
    for d, rs in rows_by_date.items():
        if d.year == target_date.year and d.month == target_date.month and d <= target_date:
            out.extend(rs)
    return out


# ── Main refresh ──────────────────────────────────────────────────────────────

UPSERT_SQL = """
INSERT INTO gold.reebok_daily_metrics (
    full_date, period_type, store_name, site_short_name,
    nsv, target, achievement_pct, bills, qty_sold,
    atv, upt, asp, fupt,
    footwear_qty, footwear_nsv, apparel_qty, apparel_nsv,
    accessories_qty, accessories_nsv, socks_qty, socks_nsv,
    sfr, afr,
    men_qty, women_qty, unisex_qty, men_nsv, women_nsv, unisex_nsv,
    division_breakdown, gender_division, staffwise
) VALUES %s
ON CONFLICT (full_date, period_type) DO UPDATE SET
    store_name         = EXCLUDED.store_name,
    site_short_name    = EXCLUDED.site_short_name,
    nsv                = EXCLUDED.nsv,
    target             = EXCLUDED.target,
    achievement_pct    = EXCLUDED.achievement_pct,
    bills              = EXCLUDED.bills,
    qty_sold           = EXCLUDED.qty_sold,
    atv                = EXCLUDED.atv,
    upt                = EXCLUDED.upt,
    asp                = EXCLUDED.asp,
    fupt               = EXCLUDED.fupt,
    footwear_qty       = EXCLUDED.footwear_qty,
    footwear_nsv       = EXCLUDED.footwear_nsv,
    apparel_qty        = EXCLUDED.apparel_qty,
    apparel_nsv        = EXCLUDED.apparel_nsv,
    accessories_qty    = EXCLUDED.accessories_qty,
    accessories_nsv    = EXCLUDED.accessories_nsv,
    socks_qty          = EXCLUDED.socks_qty,
    socks_nsv          = EXCLUDED.socks_nsv,
    sfr                = EXCLUDED.sfr,
    afr                = EXCLUDED.afr,
    men_qty            = EXCLUDED.men_qty,
    women_qty          = EXCLUDED.women_qty,
    unisex_qty         = EXCLUDED.unisex_qty,
    men_nsv            = EXCLUDED.men_nsv,
    women_nsv          = EXCLUDED.women_nsv,
    unisex_nsv         = EXCLUDED.unisex_nsv,
    division_breakdown = EXCLUDED.division_breakdown,
    gender_division    = EXCLUDED.gender_division,
    staffwise          = EXCLUDED.staffwise,
    loaded_at          = now();
"""


def refresh_reebok(verbose=True):
    print("Refreshing Uppal Reebok gold layer (R1157)...")
    conn = get_pg_conn()
    raw_rows = fetch_reebok_rows(conn)
    print(f"  Fetched {len(raw_rows)} raw rows for {UPPAL_STORE}.")

    if not raw_rows:
        print("  No rows to aggregate. Done.")
        conn.close()
        return

    rows_by_date = group_rows_by_date(raw_rows)
    print(f"  Found {len(rows_by_date)} distinct date(s).")

    today_store_name = None
    upserts = []
    for target_date in sorted(rows_by_date.keys()):
        # TODAY row
        today_metrics = aggregate_one_date(rows_by_date[target_date])
        if today_store_name is None:
            # best-effort: read store name from any raw row (default to "Reebok Uppal")
            today_store_name = "Reebok Uppal"
        upserts.append((
            target_date, "today", today_store_name, UPPAL_STORE, *today_metrics.values(),
        ))

        # MTD row (rows from 1st of month through target_date)
        mtd_rows = rows_up_to(rows_by_date, target_date)
        mtd_metrics = aggregate_one_date(mtd_rows)
        upserts.append((
            target_date, "mtd", today_store_name, UPPAL_STORE, *mtd_metrics.values(),
        ))

    if verbose:
        print(f"  Upserting {len(upserts)} rows into gold.reebok_daily_metrics...")

    cur = conn.cursor()
    execute_values(cur, UPSERT_SQL, upserts, page_size=200)
    conn.commit()
    cur.close()

    conn.close()
    print(f"  [OK] gold.reebok_daily_metrics refreshed — {len(upserts)} rows.")
    print("\n[OK] Uppal Reebok gold refresh complete!")


if __name__ == "__main__":
    refresh_reebok()
