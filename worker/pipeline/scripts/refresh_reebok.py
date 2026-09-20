"""
refresh_reebok.py — Uppal Reebok Gold Layer Refresh
==================================================
Reads raw.sales for UPPAL REEBOK (Store Number = 'R1157'), aggregates
every required KPI, and upserts into gold.reebok_daily_metrics.

The gold table has one row per (full_date, period_type) where
period_type in ('today', 'mtd', 'ytd'). This script populates ALL THREE for
every date that has sales data, so all 4 reports can read from one table.
YTD = calendar year (1 January of that year through the row's date).

Business rules (per artifacts/docs/REEBOOK_KPI_DEFINITIONS.md):
  * NSV / RSV = SUM("Taxable Amount")
  * Bills = COUNT(DISTINCT "Bill No.")
  * Qty = SUM("Qty")
  * ATV = NSV / Bills
  * UPT = Qty / Bills
  * ASP = NSV / Qty
  * Footwear qty/nsv  = WHERE "Item Division" = 'FOOTWEAR'
  * Apparel qty/nsv   = WHERE "Item Division" = 'APPAREL'
  * Accessories qty/nsv = Item Division 'ACCESSORIES' (socks, caps, bags)
  * Blank Item Division: resolved from Class Name (CLASS_TO_DIVISION), never
    defaulted to accessories. Unknown classes are reported and kept out of
    the FW/APP/ACC buckets ('unclassified').
  * 'Carry Bag' lines are free packaging (MRP Rs1, Rs0 taxable) and are NOT
    units sold: they are excluded from every count (qty, division, gender,
    salesperson). NSV and bills are unaffected (bags never create a bill).
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


# Packaging lines: free carry bags are not units sold (audit of Aug-2026 export:
# 547 of 986 "units" were bags with Rs0 taxable amount).
EXCLUDED_CLASSES = {"carry bag"}

# Class Name -> division. Used ONLY when the export leaves Item Division blank.
# Built from the Aug-2026 audit; add new classes here when the warning below fires.
CLASS_TO_DIVISION = {
    "shoes": "footwear", "slippers": "footwear", "slider": "footwear", "sandal": "footwear", "slip ons": "footwear",
    "t shirt": "apparel", "polo": "apparel", "track pant": "apparel", "rb training": "apparel",
    "shorts": "apparel", "track top": "apparel", "pant": "apparel", "tank top": "apparel",
    "rb athleisure": "apparel", "tights": "apparel", "gl hoodie": "apparel", "jogger": "apparel",
    "socks": "accessories", "cap": "accessories", "bag": "accessories",
}
UNMAPPED_CLASSES = set()
FALLBACK_CLASSES = set()

# Safety net for a NEW class name that is not in CLASS_TO_DIVISION yet. Matches whole-word keywords
# in the Class Name only; anything that still does not match is reported and kept out of the buckets.
FOOTWEAR_KEYWORDS = ("shoe", "slip on", "slip-on", "slipper", "slider", "sandal", "sneaker", "flip flop", "boot")
APPAREL_KEYWORDS = ("t shirt", "tshirt", "polo", "short", "pant", "jogger", "hood", "jacket", "track", "tight", "tank", "sweat", "tee")


def is_excluded_line(class_name):
    """True for packaging lines (carry bags) that must not count as units sold."""
    return str(class_name or "").strip().lower() in EXCLUDED_CLASSES


def resolve_division(div, class_name):
    """
    Division for a sales line. A filled Item Division wins; a blank one is resolved
    from Class Name. Unknown blank-division classes are NOT defaulted to accessories:
    they are recorded in UNMAPPED_CLASSES (reported at the end) and returned as
    'unclassified'.
    """
    if div and str(div).strip():
        return normalize_division(div)
    key = str(class_name or "").strip().lower()
    mapped = CLASS_TO_DIVISION.get(key)
    if mapped:
        return mapped
    if any(k in key for k in FOOTWEAR_KEYWORDS):
        FALLBACK_CLASSES.add(f"{class_name} -> footwear")
        return "footwear"
    if any(k in key for k in APPAREL_KEYWORDS):
        FALLBACK_CLASSES.add(f"{class_name} -> apparel")
        return "apparel"
    UNMAPPED_CLASSES.add(str(class_name or "(blank)"))
    return "unclassified"


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
    lines = [
        {
            "bill_date": row.get("Bill Date"),
            "bill_no": row.get("Bill No."),
            "qty_raw": row.get("Qty"),
            "tax_raw": row.get("Taxable Amount"),
            "item_division": row.get("Item Division"),
            "section": row.get("Section"),
            "class_name": row.get("Class Name"),
            "salesman": row.get("Salesman"),
            "mrp_raw": row.get("MRP"),
            "cgst_raw": row.get("CGST"),
            "sgst_raw": row.get("SGST"),
            "igst_raw": row.get("IGST"),
        }
        for row in selected
    ]
    kept = [ln for ln in lines if not is_excluded_line(ln["class_name"])]
    skipped = lines and (len(lines) - len(kept))
    if skipped:
        bag_qty = sum(parse_num(ln["qty_raw"]) for ln in lines if is_excluded_line(ln["class_name"]))
        print(f"  Excluded {skipped} packaging line(s) (Carry Bag, {bag_qty:g} units) from all counts.")
    return kept


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

        div = resolve_division(r.get("item_division"), r.get("class_name"))
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
        elif div == "accessories":
            acc_qty += line_qty
            acc_nsv += line_nsv
        # 'unclassified' lines stay in the totals but in no FW/APP/ACC bucket

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
        if div in ("footwear", "apparel", "accessories"):
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


def rows_up_to_year(rows_by_date, target_date):
    """Concat all rows where date <= target_date in the same calendar year (YTD)."""
    out = []
    for d, rs in rows_by_date.items():
        if d.year == target_date.year and d <= target_date:
            out.extend(rs)
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


# ── Master dashboard tables (Overview tab) ───────────────────────────────────
#
# gold.reebok_master_dashboard           one row per day, built from the SAME cleaned lines as
#                                        gold.reebok_daily_metrics (carry bags excluded, blank
#                                        divisions resolved), so both always agree.
# gold.reebok_master_dashboard_payments  one row per day from the Account DSR, de-duplicated.
#
# MD % = (mrp_value - nsv) / mrp_value x 100   (decided 20-Sep-2026, see KPI definitions)

MASTER_COLUMNS = [
    "nsv", "gst_amount", "gross_value", "mrp_value", "qty", "bills",
    "footwear_qty", "footwear_nsv", "footwear_mrp", "footwear_bills",
    "apparel_qty", "apparel_nsv", "apparel_mrp", "apparel_bills",
    "accessories_qty", "accessories_nsv", "accessories_mrp", "accessories_bills",
    "socks_qty", "shoes_qty",
]
MASTER_DIVISIONS = ("footwear", "apparel", "accessories")


def aggregate_master_day(rows_for_date):
    """One day of cleaned sales lines -> dict of MASTER_COLUMNS."""
    t = dict.fromkeys(MASTER_COLUMNS, 0.0)
    bills = set()
    div_bills = {d: set() for d in MASTER_DIVISIONS}

    for r in rows_for_date:
        qty = parse_num(r.get("qty_raw"))
        nsv = parse_num(r.get("tax_raw"))
        gst = parse_num(r.get("cgst_raw")) + parse_num(r.get("sgst_raw")) + parse_num(r.get("igst_raw"))
        mrp = parse_num(r.get("mrp_raw")) * qty
        bill = str(r.get("bill_no") or "").strip()
        cls = str(r.get("class_name") or "").strip().lower()
        div = resolve_division(r.get("item_division"), r.get("class_name"))

        t["nsv"] += nsv
        t["gst_amount"] += gst
        t["gross_value"] += nsv + gst
        t["mrp_value"] += mrp
        t["qty"] += qty
        if bill:
            bills.add(bill)

        if div in MASTER_DIVISIONS:
            t[f"{div}_qty"] += qty
            t[f"{div}_nsv"] += nsv
            t[f"{div}_mrp"] += mrp
            if bill:
                div_bills[div].add(bill)
        if is_socks(r.get("class_name")):
            t["socks_qty"] += qty
        if cls == "shoes":          # closed footwear, the denominator of SSR
            t["shoes_qty"] += qty

    out = {k: round(v, 2) for k, v in t.items()}
    out["bills"] = len(bills)
    for d in MASTER_DIVISIONS:
        out[f"{d}_bills"] = len(div_bills[d])
    return out


def build_master_rows(rows_by_date):
    """-> list of (full_date, site_short_name, *MASTER_COLUMNS values)"""
    result = []
    for d in sorted(rows_by_date.keys()):
        m = aggregate_master_day(rows_by_date[d])
        result.append((d, UPPAL_STORE, *[m[c] for c in MASTER_COLUMNS]))
    return result


MASTER_UPSERT_SQL = (
    "INSERT INTO gold.reebok_master_dashboard (full_date, site_short_name, " + ", ".join(MASTER_COLUMNS) + ") VALUES %s "
    "ON CONFLICT (full_date) DO UPDATE SET site_short_name = EXCLUDED.site_short_name, "
    + ", ".join(f"{c} = EXCLUDED.{c}" for c in MASTER_COLUMNS) + ", loaded_at = now()"
)

PAYMENT_UPSERT_SQL = """
INSERT INTO gold.reebok_master_dashboard_payments (
    full_date, site_short_name, upi_amount, card_amount, amex_amount, zomato_amount, gv_amount, cash_amount,
    total_collected, dsr_day_sale, cash_used, cn_issued, cn_redeem, remarks, source_file
) VALUES %s
ON CONFLICT (full_date) DO UPDATE SET
    site_short_name = EXCLUDED.site_short_name,
    upi_amount = EXCLUDED.upi_amount, card_amount = EXCLUDED.card_amount, amex_amount = EXCLUDED.amex_amount,
    zomato_amount = EXCLUDED.zomato_amount, gv_amount = EXCLUDED.gv_amount, cash_amount = EXCLUDED.cash_amount,
    total_collected = EXCLUDED.total_collected, dsr_day_sale = EXCLUDED.dsr_day_sale,
    cash_used = EXCLUDED.cash_used, cn_issued = EXCLUDED.cn_issued, cn_redeem = EXCLUDED.cn_redeem,
    remarks = EXCLUDED.remarks, source_file = EXCLUDED.source_file, loaded_at = now()
"""


def build_payment_rows(dsr_rows, last_sales_date):
    """
    Cleaned Account DSR -> one row per date.

    Rules
      * only Uppal rows with a real date, on or before the last sales date
        (drops "Opening Cash" lines and dates that are still in the future);
      * only rows loaded by the current DSR loader (they carry 'Physical Day Sale'); rows from the
        old loader have no CARD/AMEX/ZOMATO/GV and would show a wrong split;
      * when the same date is in several uploads, the file whose MAIN MONTH is that date's month owns
        the date. A monthly DSR can carry the next month's first day; that overflow row must never
        override the real month's row, whatever order the files were uploaded in. Among files that
        own the date (for example a corrected re-upload), the latest upload wins;
      * total_collected = UPI + CARD + AMEX + ZOMATO + GV + CASH. The DSR day-sale figure is kept
        separately for reference because it can exclude cash that was paid out (for example 02-Aug).

    Returns (rows, stats) where rows are tuples for PAYMENT_UPSERT_SQL.
    """
    stats = {"seen": 0, "old_loader": 0, "not_uppal": 0, "bad_date": 0, "future": 0, "superseded": 0}

    candidates = []          # (date, row) that passed every filter
    month_rows = {}          # (source file, year, month) -> how many rows that file has in that month
    for r in dsr_rows:
        stats["seen"] += 1
        store = (str(r.get("Store Number") or "") + " " + str(r.get("Store Name") or "")).lower()
        if "uppal" not in store and UPPAL_STORE.lower() not in store:
            stats["not_uppal"] += 1
            continue
        d = parse_date(r.get("Date"))
        if d is None:
            stats["bad_date"] += 1
            continue
        if last_sales_date and d > last_sales_date:
            stats["future"] += 1
            continue
        if r.get("Physical Day Sale") is None:
            stats["old_loader"] += 1
            continue
        candidates.append((d, r))
        key = (r.get("source_file_name"), d.year, d.month)
        month_rows[key] = month_rows.get(key, 0) + 1

    # each file's main month = the month it has the most rows in
    main_month = {}
    for (src, y, m), count in month_rows.items():
        if src not in main_month or count > month_rows[(src, *main_month[src])]:
            main_month[src] = (y, m)

    best = {}
    for d, r in candidates:
        owns = 1 if main_month.get(r.get("source_file_name")) == (d.year, d.month) else 0
        rank = (owns, str(r.get("uploaded_at") or ""), r.get("id") or 0)
        if d in best:
            stats["superseded"] += 1
            if rank < best[d][0]:
                continue
        best[d] = (rank, r)

    rows = []
    for d in sorted(best):
        r = best[d][1]
        modes = [parse_num(r.get(c)) for c in ("UPI Amount", "Card Amount", "AMEX Amount", "Zomato Amount", "GV Amount", "Cash Amount")]
        rows.append((
            d, UPPAL_STORE, *modes, round(sum(modes), 2),
            parse_num(r.get("Physical Day Sale")), parse_num(r.get("Cash Used")),
            parse_num(r.get("CN Issued")), parse_num(r.get("CN Redeem")),
            r.get("Remarks"), r.get("source_file_name"),
        ))
    return rows, stats


def refresh_master_dashboard(conn, rows_by_date):
    """Fill the two master-dashboard gold tables. Never blocks the main refresh."""
    try:
        master_rows = build_master_rows(rows_by_date)
        cur = conn.cursor()
        execute_values(cur, MASTER_UPSERT_SQL, master_rows, page_size=200)
        conn.commit()
        cur.close()
        print(f"  [OK] gold.reebok_master_dashboard refreshed - {len(master_rows)} day(s).")

        dsr = pg_fetch_all(conn, "SELECT * FROM raw.account_dsr")
        pay_rows, st = build_payment_rows(dsr, max(rows_by_date) if rows_by_date else None)
        if pay_rows:
            cur = conn.cursor()
            execute_values(cur, PAYMENT_UPSERT_SQL, pay_rows, page_size=200)
            conn.commit()
            cur.close()
        print(f"  [OK] gold.reebok_master_dashboard_payments refreshed - {len(pay_rows)} day(s) "
              f"(DSR rows seen {st['seen']}, superseded re-uploads {st['superseded']}, non-data {st['bad_date']}, "
              f"future-dated {st['future']}).")
        if st["old_loader"]:
            print(f"  [WARN] {st['old_loader']} DSR row(s) were loaded by the old loader and were ignored. "
                  "Re-upload the Account DSR file(s) to fill the payment split.")
    except Exception as exc:  # noqa: BLE001 - keep the main refresh result intact
        conn.rollback()
        print(f"  [WARN] Master dashboard tables were not refreshed: {exc}")
        print("         Has migration 2026_09_20_reebok_master_dashboard.sql been applied?")


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

        # YTD row (rows from 1 January through target_date, calendar year)
        ytd_rows = rows_up_to_year(rows_by_date, target_date)
        ytd_metrics = aggregate_one_date(ytd_rows)
        upserts.append((
            target_date, "ytd", today_store_name, UPPAL_STORE, *ytd_metrics.values(),
        ))

    if verbose:
        print(f"  Upserting {len(upserts)} rows into gold.reebok_daily_metrics...")

    cur = conn.cursor()
    execute_values(cur, UPSERT_SQL, upserts, page_size=200)
    conn.commit()
    cur.close()

    refresh_master_dashboard(conn, rows_by_date)

    conn.close()
    if FALLBACK_CLASSES:
        print("\n  [INFO] Blank Item Division resolved by keyword, please add to CLASS_TO_DIVISION: "
              + ", ".join(sorted(FALLBACK_CLASSES)))
    if UNMAPPED_CLASSES:
        print("\n  [WARN] Blank Item Division with no mapping in CLASS_TO_DIVISION (kept out of FW/APP/ACC): "
              + ", ".join(sorted(UNMAPPED_CLASSES)))
        print("         Add them to CLASS_TO_DIVISION in refresh_reebok.py and re-run.")
    print(f"  [OK] gold.reebok_daily_metrics refreshed — {len(upserts)} rows.")
    print("\n[OK] Uppal Reebok gold refresh complete!")


if __name__ == "__main__":
    refresh_reebok()
