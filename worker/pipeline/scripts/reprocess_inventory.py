"""
reprocess_inventory.py — one-off: re-ingest every stored stock file with the fixed ingest
=========================================================================================
Before 2026-10-01 the stock ingest stored Style Code as "Bar Code", dropped Last Inwarded Date /
cost / MRP value, and loaded 0 rows from every file whose first sheet is a pivot (6 of 8 files,
all marked 'completed'). This script, for every COMPLETED inventory upload in public.upload_audit_log (queued ones
are left to the normal processing run):
  1. deletes that upload's raw.inventory rows,
  2. downloads the file from storage and ingests it with ingest_inventory_file(),
  3. records the real row count,
then rebuilds staging + gold in the same order as a normal processing run (build_dimensions
CASCADE-truncates dim_product, which empties fact_sales/fact_stock, so every later stage must run).

Destructive while it runs (hard rule 13: gold TRUNCATE + re-insert), so reports are briefly
empty. Refuses to start while a processing run is queued/processing.

    python scripts/reprocess_inventory.py            # dry run: lists the files
    python scripts/reprocess_inventory.py --apply
"""

import sys
import tempfile
import time

sys.path.append(__file__.rsplit("scripts", 1)[0])  # ingest_file.py; scripts/ stays first (two run_pipeline.py exist)

from run_pipeline import get_pg_conn, pg_select, pg_update, download_from_storage  # noqa: E402
from ingest_file import ingest_inventory_file, inventory_snapshot_date  # noqa: E402
from build_dimensions import build_dimensions  # noqa: E402
from refresh_stock import refresh_stock  # noqa: E402
from refresh_gold import refresh_gold  # noqa: E402
from refresh_reebok import refresh_reebok  # noqa: E402
from refresh_reebok_staging import refresh_reebok_staging  # noqa: E402
from refresh_category_drilldown import refresh_category_drilldown  # noqa: E402


def main(apply):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    conn = get_pg_conn()
    active = pg_select(conn, "SELECT id, status FROM public.processing_runs WHERE status IN ('queued', 'processing')")
    if active:
        conn.close()
        raise SystemExit(f"A processing run is active ({active}); wait for it to finish.")
    uploads = pg_select(
        conn,
        "SELECT id, original_file_name, storage_path, uploaded_at, status, row_count "
        "FROM public.upload_audit_log WHERE report_type = 'inventory' AND status = 'completed' "
        "ORDER BY uploaded_at",
    )
    for u in uploads:
        print(f"  {u['original_file_name']}  status={u['status']} rows={u['row_count']}  "
              f"-> stock date {inventory_snapshot_date(u['original_file_name'], u['uploaded_at'])}")
    if not apply:
        conn.close()
        print("Dry run. Re-run with --apply to reprocess.")
        return

    with tempfile.TemporaryDirectory() as tmpdir:
        for u in uploads:
            local_path = download_from_storage(u["storage_path"], tmpdir)
            pg_update(conn, "DELETE FROM raw.inventory WHERE upload_audit_id = %s", (u["id"],))
            n = ingest_inventory_file(
                local_path, conn, upload_audit_id=u["id"],
                stock_date=inventory_snapshot_date(u["original_file_name"], u["uploaded_at"]),
            )
            pg_update(conn, "UPDATE public.upload_audit_log SET row_count = %s WHERE id = %s", (n, u["id"]))
    conn.close()

    for name, task in (
        ("staging dimensions", build_dimensions),
        ("staging stock facts", refresh_stock),
        ("gold dashboard", refresh_gold),
        ("Reebok metrics", refresh_reebok),
        ("Reebok staging", refresh_reebok_staging),
        ("Reebok category drill-down", refresh_category_drilldown),
    ):
        started = time.monotonic()
        print(f"--- {name} ---")
        task()
        print(f"{name} finished in {time.monotonic() - started:.1f}s")
    print("[OK] Inventory reprocessed.")


if __name__ == "__main__":
    main("--apply" in sys.argv)
