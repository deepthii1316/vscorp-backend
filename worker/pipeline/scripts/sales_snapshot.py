"""Select authoritative rows when raw.sales contains overlapping snapshots."""

from collections import defaultdict
from datetime import datetime


IDENTITY_FIELDS = (
    "Store Number", "Store Name", "SAP Code", "Bar Code", "Item Description",
    "Size", "MRP", "Bill No.", "Bill Date", "Qty", "Disc %", "Value",
    "CGST", "SGST", "IGST", "Taxable Amount", "Brand", "Section", "Category",
    "Region", "State Name", "Store GSTIN", "Salesman", "Sales Promo Code",
    "Sales Promo Description", "HSN Code", "Style Code", "Item Division",
    "Class Name", "Sub Class",
)


def _parse_date(value):
    if not value:
        return None
    text = str(value).strip().split()[0]
    for fmt in ("%d-%m-%Y", "%Y-%m-%d", "%d/%m/%Y", "%Y/%m/%d"):
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    return None


def _parse_timestamp(value):
    if not value:
        return datetime.min
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        return datetime.min


def select_authoritative_sales_rows(rows):
    """Keep one latest, fullest snapshot for each store/month/date.

    MTD exports overlap by design. For each date, prefer the source file that
    contains the furthest date in that month; upload time breaks ties.
    """
    source_dates = defaultdict(set)
    source_uploaded_at = {}
    for row in rows:
        bill_date = _parse_date(row.get("Bill Date"))
        source = row.get("source_file_name")
        if not bill_date or not source:
            continue
        source_key = (row.get("Store Number"), bill_date.year, bill_date.month, source)
        source_dates[source_key].add(bill_date)
        source_uploaded_at[source_key] = max(
            source_uploaded_at.get(source_key, datetime.min),
            _parse_timestamp(row.get("uploaded_at")),
        )

    winning_sources = {}
    for row in rows:
        bill_date = _parse_date(row.get("Bill Date"))
        if not bill_date:
            continue
        month_key = (row.get("Store Number"), bill_date.year, bill_date.month)
        candidates = [
            source_key for source_key, dates in source_dates.items()
            if source_key[:3] == month_key and bill_date in dates
        ]
        if candidates:
            winner = max(
                candidates,
                key=lambda key: (
                    max(source_dates[key]),
                    source_uploaded_at[key],
                    key[-1],
                ),
            )
            winning_sources[(month_key, bill_date)] = winner[-1]

    selected = []
    seen = set()
    for row in rows:
        bill_date = _parse_date(row.get("Bill Date"))
        if not bill_date:
            continue
        month_key = (row.get("Store Number"), bill_date.year, bill_date.month)
        if row.get("source_file_name") != winning_sources.get((month_key, bill_date)):
            continue
        identity = tuple(row.get(field) for field in IDENTITY_FIELDS)
        if identity in seen:
            continue
        seen.add(identity)
        selected.append(row)
    return selected
