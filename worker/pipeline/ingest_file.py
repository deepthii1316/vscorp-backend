"""
ingest_file.py — Raw Layer Ingestion
====================================
Reads Excel/CSV files and inserts rows into raw.* tables using psycopg2
(direct Postgres — no httpx, no SSL cert issues).

Functions called by run_pipeline.py:
  ingest_sales_file(filepath, pg_conn)
  ingest_account_dsr_file(filepath, pg_conn)
  ingest_inventory_file(filepath, pg_conn)
"""

import os
import re
import sys
import io
import pandas as pd
import hashlib
from datetime import datetime, timedelta, timezone
from dotenv import load_dotenv
from pathlib import Path
from psycopg2.extras import execute_values

load_dotenv(Path(__file__).resolve().parent / ".env")


# ── helpers ────────────────────────────────────────────────────────────────────

def calculate_sha256(filepath):
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        for block in iter(lambda: f.read(4096), b""):
            h.update(block)
    return h.hexdigest()


def to_text(val):
    """Convert a cell value to text or None."""
    if val is None:
        return None
    if isinstance(val, float) and pd.isna(val):
        return None
    s = str(val).strip()
    return s if s.lower() not in ("", "nan", "none", "null", "n/a") else None


def read_excel_auto(filepath):
    """Read Excel/CSV, auto-detecting header row. Returns (df, filename)."""
    ext = os.path.splitext(filepath)[1].lower()
    if ext == ".csv":
        df = pd.read_csv(filepath, dtype=str, keep_default_na=False)
        df.columns = df.columns.str.strip()
        return df

    # Try header offsets 0..9 to find a real header row.
    # A real header is identified by: known business terms OR few Unnamed columns.
    known_terms = ["store", "site", "bill", "date", "barcode", "bar code",
                   "item", "product", "section", "department", "division",
                   "mrp", "value", "amount", "qty", "quantity", "hsn",
                   "gstin", "salesman", "promo", "size", "category",
                   "sap", "code", "bill date", "upi", "card", "cash",
                   "physical day sale", "system day sale", "store name"]
    best = None
    best_score = -1
    for h in range(10):
        try:
            df = pd.read_excel(filepath, dtype=str, header=h)
            df.columns = [str(c).strip() for c in df.columns]
            col_str = " ".join(df.columns).lower()
            unnamed_count = sum(1 for c in df.columns if c.lower().startswith("unnamed") or not c)
            score = (sum(1 for t in known_terms if t in col_str) * 10) - min(unnamed_count, 10)
            if score > best_score:
                best_score = score
                best = df
        except Exception:
            continue

    if best is not None and best_score > 0:
        return best

    # Fallback: row 7 (matches original code)
    df = pd.read_excel(filepath, dtype=str, header=7)
    df = df.loc[:, [not str(column).startswith("Unnamed") for column in df.columns]]
    df.columns = [str(column).strip() for column in df.columns]
    return df


# ── sales ─────────────────────────────────────────────────────────────────────

def _clean_sales_row(r):
    """r is a dict from df.iterrows() — column name → value."""
    def gv(keys):
        for k in keys:
            if k in r and r[k] is not None:
                s = str(r[k]).strip()
                if s and s.lower() not in ("nan", "none", "null", ""):
                    return s
            # Case-insensitive fallback
            for col, val in r.items():
                if str(col).strip().lower() == k.lower():
                    if val is not None:
                        s = str(val).strip()
                        if s and s.lower() not in ("nan", "none", "null", ""):
                            return s
        return None

    return (
        gv(["Store Number"]),
        gv(["Store Name"]),
        gv(["SAP CODE", "SAP Code"]),
        gv(["Stock No.", "Bar Code"]),
        gv(["Item Description"]),
        gv(["Size Code", "Size"]),
        gv(["MRP"]),
        gv(["Bill No."]),
        gv(["Bill Date"]),
        gv(["Quantity", "Qty"]),
        gv(["Total Discount", "Disc %"]),
        gv(["Value"]),
        gv(["CGST Value", "CGST"]),
        gv(["SGST Value", "SGST"]),
        gv(["IGST Value", "IGST"]),
        gv(["Taxable Amount"]),
        gv(["DIVISION", "Brand"]),
        gv(["GROUP", "Section"]),
        gv(["Department", "Category"]),
        gv(["Region"]),
        gv(["State Name"]),
        gv(["Store GSTIN"]),
        gv(["Salesman"]),
        gv(["Sales Promo Code"]),
        gv(["Sales Promo Description"]),
        gv(["HSN Code"]),
        gv(["Style Code"]),
        gv(["Item Division"]),
        gv(["Class Name"]),
        gv(["Sub Class"]),
    )


def ingest_sales_file(filepath, pg_conn, uploaded_by="admin", upload_audit_id=None):
    """Insert sales rows into raw.sales. Returns row count."""
    print(f"Ingesting sales file: {os.path.basename(filepath)}")
    df = read_excel_auto(filepath)

    # Drop rows with no Store Number (case-insensitive lookup)
    sn_col = None
    for c in df.columns:
        if c.strip().lower() == "store number":
            sn_col = c
            break
    if not sn_col:
        print(f"  ERROR: No 'Store Number' column found. Columns: {list(df.columns)[:10]}")
        return 0
    df = df[df[sn_col].notna()]
    df = df[~df[sn_col].astype(str).str.strip().eq("")]

    # The SAP export ends with summary lines ("Bill Value :", "Round-Off Value :", "Total Bill Value :").
    # They carry a label in the Store Number column but no bill, and must never become sales rows
    # (they also used to create fake stores in staging.dim_store). Every real sales line has a Bill No.
    bill_col = next((c for c in df.columns if c.strip().lower() == "bill no."), None)
    rows_before = len(df)
    df = df[~df[sn_col].astype(str).str.strip().str.endswith(":")]
    if bill_col:
        bill = df[bill_col].astype(str).str.strip()
        has_bill = df[bill_col].notna() & ~bill.str.lower().isin(["", "nan", "none", "null"]) & ~bill.str.contains("total", case=False)
        df = df[has_bill]
    if rows_before - len(df):
        print(f"  Skipped {rows_before - len(df)} footer/summary line(s) (no Bill No. or a 'Value :' label).")

    # Reformat dates
    if "Bill Date" in df.columns:
        df["Bill Date"] = pd.to_datetime(df["Bill Date"], errors="coerce")
        df["Bill Date"] = df["Bill Date"].dt.strftime("%d-%m-%Y")

    now_str = datetime.now(timezone.utc).isoformat()
    renamed_name = os.path.basename(filepath)

    rows = []
    for source_row_number, (_, r) in enumerate(df.iterrows(), start=1):
        vals = _clean_sales_row(r)
        rows.append(vals + (
            now_str, uploaded_by, renamed_name, "manual",
            upload_audit_id, source_row_number,
        ))

    if not rows:
        print("  No valid sales records found.")
        return 0

    BATCH_SIZE = 500
    total = 0
    cols = (
        "Store Number", "Store Name", "SAP Code", "Bar Code",
        "Item Description", "Size", "MRP", "Bill No.", "Bill Date",
        "Qty", "Disc %", "Value", "CGST", "SGST", "IGST",
        "Taxable Amount", "Brand", "Section", "Category",
        "Region", "State Name", "Store GSTIN", "Salesman",
        "Sales Promo Code", "Sales Promo Description",
        "HSN Code", "Style Code", "Item Division", "Class Name", "Sub Class",
        "uploaded_at", "uploaded_by", "source_file_name", "ingestion_method",
        "upload_audit_id", "source_row_number"
    )
    # Quote column names that contain spaces or special chars
    quoted_cols = ", ".join(f'"{c.replace("%", "%%")}"' for c in cols)
    sql = (
        f"INSERT INTO raw.sales ({quoted_cols}) VALUES %s "
        "ON CONFLICT (upload_audit_id, source_row_number) "
        "WHERE upload_audit_id IS NOT NULL DO NOTHING"
    )

    cur = pg_conn.cursor()
    for i in range(0, len(rows), BATCH_SIZE):
        batch = rows[i : i + BATCH_SIZE]
        execute_values(cur, sql, batch, page_size=BATCH_SIZE)
        total += len(batch)
    pg_conn.commit()
    cur.close()

    print(f"  Ingested {total} rows into raw.sales.")
    return total


# ── account_dsr ───────────────────────────────────────────────────────────────

def _dsr_norm(col):
    """Normalise a DSR header: lower-case, single spaces."""
    return " ".join(str(col).strip().lower().split())


def _dsr_num(val):
    """DSR cells use '-' for zero and may contain thousands separators."""
    if val is None:
        return 0.0
    s = str(val).strip().replace(",", "")
    if s in ("", "-", "nan", "none", "null", "n/a"):
        return 0.0
    try:
        return float(s)
    except ValueError:
        return 0.0


def _dsr_num_str(val):
    n = _dsr_num(val)
    return str(int(n)) if n == int(n) else str(round(n, 2))


def ingest_account_dsr_file(filepath, pg_conn, uploaded_by="admin", upload_audit_id=None):
    """
    Insert Reebok Account DSR rows into raw.account_dsr. Returns row count.

    The DSR has one row per day with these headers (matched exactly, case-insensitive):
      Store name, Date, UPI, CARD, AMEX, ZOMATO, GV, CASH, SYSTEM DAY SALE, PHYSICAL DAY SALE,
      Diff, CN Issued, CN Redeem, CASH USED, PAYTM CARD, PAYTM, Remarks for Excess / Shortage
    Rows whose Date is not a real date (for example the "Opening Cash" line) are skipped.
    """
    print(f"Ingesting account_dsr file: {os.path.basename(filepath)}")
    df = read_excel_auto(filepath)

    now_str = datetime.now(timezone.utc).isoformat()
    renamed_name = os.path.basename(filepath)
    norm_cols = {_dsr_norm(c): c for c in df.columns}

    def cell(r, header):
        col = norm_cols.get(header)
        if col is None:
            return None
        v = r[col]
        if v is None:
            return None
        s = str(v).strip()
        return None if s.lower() in ("", "nan", "none", "null") else s

    missing = [h for h in ("date", "store name", "upi", "card", "cash", "physical day sale") if h not in norm_cols]
    if missing:
        raise ValueError(f"Account DSR is missing expected column(s): {', '.join(missing)}. Found: {', '.join(df.columns)}")

    rows = []
    skipped = 0
    for source_row_number, (_, r) in enumerate(df.iterrows(), start=1):
        date = cell(r, "date")
        store = cell(r, "store name")
        if not date or not store or pd.isna(pd.to_datetime(date, errors="coerce")):
            skipped += 1
            continue

        upi, card, cash = _dsr_num(cell(r, "upi")), _dsr_num(cell(r, "card")), _dsr_num(cell(r, "cash"))
        amex, zomato, gvv = _dsr_num(cell(r, "amex")), _dsr_num(cell(r, "zomato")), _dsr_num(cell(r, "gv"))
        rows.append((
            date,
            store,
            store,
            "0",                                        # Total Bills (not in the DSR)
            _dsr_num_str(cell(r, "physical day sale")), # Total Sales = PHYSICAL DAY SALE
            _dsr_num_str(cash),
            "0",
            _dsr_num_str(card),
            "0",
            _dsr_num_str(upi),
            "0",
            _dsr_num_str(amex + zomato + gvv),          # Other Amount = AMEX + ZOMATO + GV
            "0",
            _dsr_num_str(amex),
            _dsr_num_str(zomato),
            _dsr_num_str(gvv),
            _dsr_num_str(cell(r, "system day sale")),
            _dsr_num_str(cell(r, "physical day sale")),
            _dsr_num_str(cell(r, "diff")),
            _dsr_num_str(cell(r, "cn issued")),
            _dsr_num_str(cell(r, "cn redeem")),
            _dsr_num_str(cell(r, "cash used")),
            _dsr_num_str(cell(r, "paytm")),
            _dsr_num_str(cell(r, "paytm card")),
            cell(r, "remarks for excess / shortage"),
            now_str,
            uploaded_by,
            renamed_name,
            "manual",
            upload_audit_id,
            source_row_number,
        ))

    if skipped:
        print(f"  Skipped {skipped} non-data row(s) (no valid date, e.g. 'Opening Cash').")
    if not rows:
        print("  No valid Account DSR records found.")
        return 0

    cols = (
        "Date", "Store Number", "Store Name", "Total Bills", "Total Sales",
        "Cash Amount", "Cash Bills", "Card Amount", "Card Bills",
        "UPI Amount", "UPI Bills", "Other Amount", "Other Bills",
        "AMEX Amount", "Zomato Amount", "GV Amount", "System Day Sale", "Physical Day Sale",
        "Diff", "CN Issued", "CN Redeem", "Cash Used", "Paytm Amount", "Paytm Card Amount", "Remarks",
        "uploaded_at", "uploaded_by", "source_file_name", "ingestion_method",
        "upload_audit_id", "source_row_number"
    )
    quoted_cols = ", ".join(f'"{c}"' for c in cols)
    sql = (
        f"INSERT INTO raw.account_dsr ({quoted_cols}) VALUES %s "
        "ON CONFLICT (upload_audit_id, source_row_number) "
        "WHERE upload_audit_id IS NOT NULL DO NOTHING"
    )

    cur = pg_conn.cursor()
    execute_values(cur, sql, rows, page_size=1000)
    pg_conn.commit()
    cur.close()

    print(f"  Ingested {len(rows)} rows into raw.account_dsr.")
    return len(rows)


# ── inventory ────────────────────────────────────────────────────────────────

# raw.inventory column -> source header(s) in the "Stock Balance - Detailed" export.
# Headers are matched EXACTLY (case/whitespace-insensitive), never by substring: substring
# matching once stored "Style Code" in "Bar Code" (because "Style Code" was tried before "EAN")
# and "Item Division" in "Brand" (because "division" is a substring of it), which left 0 stock
# rows joinable to sales. "Bar Code" must be the EAN — sales "Bar Code" is the EAN too.
INVENTORY_COLUMNS = {
    "Store Number":       ["Store Code", "Store Number"],
    "Store Name":         ["Store Name"],
    "SAP Code":           ["SAPCODE", "SAP Code"],
    "Bar Code":           ["EAN", "Bar Code", "Barcode"],
    "Item Description":   ["Product Name", "Item Description"],
    "Size":               ["Size"],
    "MRP":                ["MRP"],
    "Stock Qty":          ["Quantity", "Closing Qty", "Stock Qty"],
    "Stock Value":        ["Total Stock With Tax"],
    "Brand":              ["DIVISION"],
    "Section":            ["Group Name"],
    "Category":           ["Department"],
    "SKU":                ["SKU"],
    "Style Code":         ["Style Code"],
    "Item Division":      ["Item Division"],
    "Class Name":         ["Category"],
    "Sub Class":          ["Subclass"],
    "Color":              ["Color"],
    "Gender":             ["Gender"],
    "Last Inwarded Date": ["Last Inwarded Date"],
    "Inward Type":        ["Inward Type"],
    "Unit Cost":          ["Unit Cost"],
    "Cost Value":         ["Cost Value"],
    "MRP Value":          ["Value"],
}
INVENTORY_REQUIRED = ("Bar Code", "Stock Qty")


def _norm_header(h):
    return re.sub(r"\s+", " ", str(h)).strip().lower()


def read_inventory_sheet(filepath):
    """
    Find the stock detail table in any sheet. The export has a title row above the header, and
    from 2026-09-23 the file starts with a pivot sheet ("Row Labels" / "Sum of Quantity"), so
    neither header row 0 nor sheet 0 can be assumed. Returns (df, sheet_name) for the first
    sheet with a header row (within the first 10 rows) that has every required column, else
    raises — a stock file that yields no table must fail loudly, never "complete" with 0 rows.
    """
    required = {r: [_norm_header(a) for a in INVENTORY_COLUMNS[r]] for r in INVENTORY_REQUIRED}
    xl = pd.ExcelFile(filepath)
    for sheet in xl.sheet_names:
        head = pd.read_excel(xl, sheet_name=sheet, header=None, dtype=str, nrows=10)
        for idx, row in head.iterrows():
            names = {_norm_header(v) for v in row if isinstance(v, str)}
            if all(any(a in names for a in aliases) for aliases in required.values()):
                df = pd.read_excel(xl, sheet_name=sheet, header=idx, dtype=str)
                df.columns = [_norm_header(c) for c in df.columns]
                return df, sheet
    raise ValueError(
        f"No sheet in {os.path.basename(filepath)} has a stock table header with "
        + " and ".join(f"one of {INVENTORY_COLUMNS[r]}" for r in INVENTORY_REQUIRED)
        + f" (sheets: {xl.sheet_names})"
    )


def inventory_snapshot_date(original_file_name, uploaded_at):
    """
    The date a stock file describes. The export is named
    "Stock Balance Report - 2026-09-30T224244.748.xlsx" (export time, usually late evening =
    that day's closing stock). Older/renamed files fall back to the upload date in IST.
    Returns 'YYYY-MM-DD'.
    """
    m = re.search(r"(\d{4}-\d{2}-\d{2})T\d", original_file_name or "")
    if m:
        return m.group(1)
    if isinstance(uploaded_at, str):
        uploaded_at = datetime.fromisoformat(uploaded_at)
    if uploaded_at is None:
        uploaded_at = datetime.now(timezone.utc)
    if uploaded_at.tzinfo is None:
        uploaded_at = uploaded_at.replace(tzinfo=timezone.utc)
    return (uploaded_at.astimezone(timezone(timedelta(hours=5, minutes=30)))).strftime("%Y-%m-%d")


def ingest_inventory_file(filepath, pg_conn, uploaded_by="admin", upload_audit_id=None, stock_date=None):
    """Insert inventory rows into raw.inventory. Returns row count (raises if there are none)."""
    print(f"Ingesting inventory file: {os.path.basename(filepath)}")
    df, sheet = read_inventory_sheet(filepath)
    stock_date = stock_date or inventory_snapshot_date(None, None)
    print(f"  Sheet '{sheet}', {len(df)} line(s), stock date {stock_date}.")

    # Excel date cells arrive as '2026-06-29 00:00:00' even under dtype=str; store ISO dates.
    if "last inwarded date" in df.columns:
        parsed = pd.to_datetime(df["last inwarded date"], errors="coerce")
        df["last inwarded date"] = parsed.dt.strftime("%Y-%m-%d")

    now_str = datetime.now(timezone.utc).isoformat()
    renamed_name = os.path.basename(filepath)

    source_col = {}
    for target, aliases in INVENTORY_COLUMNS.items():
        source_col[target] = next((_norm_header(a) for a in aliases if _norm_header(a) in df.columns), None)
    missing = [t for t, c in source_col.items() if c is None]
    if missing:
        print(f"  [WARN] Stock file has no column for: {', '.join(missing)} (stored as NULL).")

    # The stock report ends with a summary line ("Grand Total:") that carries the label in a code
    # column and the store's total quantity/value. It must never be stored as a product.
    total_label = re.compile(r"^\s*(grand\s+|sub\s*)?total\s*:?\s*$", re.IGNORECASE)
    total_lines = 0

    targets = list(INVENTORY_COLUMNS)
    rows = []
    for source_row_number, (_, r) in enumerate(df.iterrows(), start=1):
        vals = {t: (to_text(r[c]) if c else None) for t, c in source_col.items()}
        if any(total_label.match(vals[k] or "") for k in ("Bar Code", "Store Number", "Item Description", "SAP Code")):
            total_lines += 1
            continue
        if not vals["Bar Code"]:
            continue
        rows.append(tuple(vals[t] for t in targets) + (
            stock_date,
            now_str,
            uploaded_by,
            renamed_name,
            "manual",
            upload_audit_id,
            source_row_number,
        ))

    if total_lines:
        print(f"  Skipped {total_lines} total/summary line(s) (e.g. 'Grand Total:').")
    if not rows:
        raise ValueError(f"No stock lines with an EAN found in sheet '{sheet}'.")

    cols = tuple(targets) + (
        "Stock Date",
        "uploaded_at", "uploaded_by", "source_file_name", "ingestion_method",
        "upload_audit_id", "source_row_number"
    )
    quoted_cols = ", ".join(f'"{c}"' for c in cols)
    sql = (
        f"INSERT INTO raw.inventory ({quoted_cols}) VALUES %s "
        "ON CONFLICT (upload_audit_id, source_row_number) "
        "WHERE upload_audit_id IS NOT NULL DO NOTHING"
    )

    cur = pg_conn.cursor()
    execute_values(cur, sql, rows, page_size=1000)
    pg_conn.commit()
    cur.close()

    print(f"  Ingested {len(rows)} rows into raw.inventory.")
    return len(rows)


# ── CLI entry point ──────────────────────────────────────────────────────────
# Kept for manual testing:  python ingest_file.py <filepath> [uploaded_by]

if __name__ == "__main__":
    import psycopg2
    from dotenv import load_dotenv
    from pathlib import Path

    fp = sys.argv[1] if len(sys.argv) > 1 else None
    uploaded_by = sys.argv[2] if len(sys.argv) > 2 else "admin"

    if not fp:
        data_dir = Path(__file__).resolve().parent / "data"
        files = sorted(data_dir.glob("*.xlsx"))
        if not files:
            print(f"No .xlsx files found in {data_dir}")
            sys.exit(1)
        fp = str(files[0])
        print(f"Using file: {fp}")

    load_dotenv(Path(__file__).resolve().parent / ".env")
    DB_URL = os.environ.get("SUPABASE_DB_URL")
    if not DB_URL:
        print("Error: SUPABASE_DB_URL not set")
        sys.exit(1)

    conn = psycopg2.connect(DB_URL, connect_timeout=30)
    count = ingest_sales_file(fp, conn, uploaded_by)
    conn.close()
    print(f"Done. Ingested {count} rows.")
