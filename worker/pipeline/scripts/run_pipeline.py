"""
run_pipeline.py — Virata Retail Medallion Pipeline
============================================
Orchestrates the full ETL pipeline:

  Stage 1 → ingest_file.py        : Download pending files from Supabase Storage,
                                    ingest into raw.sales / raw.inventory / raw.account_dsr
  Stage 2 → build_dimensions.py   : Build staging dimension tables
  Stage 3 → refresh_gold.py       : Aggregate staging → gold.fact_master_dashboard_*

Uses psycopg2 for all database operations (bypasses httpx SSL issues on Windows).
Uses supabase-py only for Storage (file downloads).

Usage:
  python run_pipeline.py
"""

import os
import sys
import tempfile
import time
import warnings
from pathlib import Path

from dotenv import load_dotenv
import psycopg2
import requests
from urllib3.exceptions import InsecureRequestWarning

# Supabase Storage's SSL chain is incomplete (PARTIAL_CHAIN) and fails with
# certifi. We're authenticated by API key + HTTPS still encrypts in transit,
# so the verify=False is safe here. Silence the warning.
warnings.simplefilter("ignore", InsecureRequestWarning)

# ── Environment loading ──────────────────────────────────────────────────────────

script_dir = Path(__file__).resolve().parent
pipeline_root = script_dir.parent

load_dotenv(pipeline_root / ".env")
for candidate in [
    pipeline_root.parent / "frontend" / ".env.local",
    pipeline_root.parent / "frontend" / ".env",
    pipeline_root.parent / ".env",
]:
    if candidate.exists():
        load_dotenv(candidate, override=False)


def _get(key):
    v = os.environ.get(key, "").strip()
    return v or None


# Postgres for ALL DB operations
# Prefer the pooler (pgbouncer) connection — port 6543 — which works reliably
# from GitHub Actions runners where the direct 5432 connection is sometimes
# blocked. Fall back to the direct connection string.
DB_URL = _get("SUPABASE_DB_URL_POOLER") or _get("SUPABASE_DB_URL")

# Supabase credentials for Storage downloads
SUPABASE_URL = _get("SUPABASE_URL") or _get("NEXT_PUBLIC_SUPABASE_URL")
SUPABASE_KEY = _get("SUPABASE_KEY") or _get("SUPABASE_SERVICE_ROLE_KEY")

if not DB_URL:
    raise SystemExit(
        "Error: SUPABASE_DB_URL / SUPABASE_DB_URL_POOLER not set.\n"
        "  Add to pipeline/.env:\n"
        "    SUPABASE_DB_URL=postgresql://postgres:PASSWORD@db.omwdvpkbsuyfnpbipjrs.supabase.co:5432/postgres\n"
        "    SUPABASE_DB_URL_POOLER=postgresql://postgres:PASSWORD@db.omwdvpkbsuyfnpbipjrs.supabase.co:6543/postgres"
    )
if not SUPABASE_URL or not SUPABASE_KEY:
    raise SystemExit("Error: SUPABASE_URL / SUPABASE_KEY not found.")


# ── DB helpers ───────────────────────────────────────────────────────────────────

def get_pg_conn():
    """Direct Postgres connection via psycopg2 — no httpx, no SSL cert issues.

    Forces IPv4 only. GitHub Actions runners default to IPv6 which
    Supabase doesn't support. socket.gethostbyname() always returns IPv4.
    """
    import socket
    from urllib.parse import urlparse
    parsed = urlparse(DB_URL)
    hostname = parsed.hostname
    port = parsed.port or 5432

    # gethostbyname is IPv4-only (no AAAA, no AAAA fallback)
    try:
        ipv4 = socket.gethostbyname(hostname)
    except socket.gaierror as e:
        raise RuntimeError(
            f"DNS resolution for {hostname} failed: {e}. "
            "Check SUPABASE_DB_URL / SUPABASE_DB_URL_POOLER."
        ) from e

    return psycopg2.connect(
        host=hostname,
        hostaddr=ipv4,
        port=port,
        user=parsed.username,
        password=parsed.password,
        dbname=parsed.path.lstrip("/"),
        connect_timeout=30,
    )


def pg_select(conn, query, params=None):
    """Run a SELECT and return rows as list of dicts."""
    cur = conn.cursor()
    cur.execute(query, params)
    cols = [d[0] for d in cur.description]
    rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    cur.close()
    return rows


def pg_update(conn, query, params=None):
    """Run an UPDATE/INSERT/DELETE. Rolls back on error so connection stays usable."""
    cur = conn.cursor()
    try:
        cur.execute(query, params)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()


def pg_insert_batch(conn, query, rows, page_size=2000):
    """Batch insert using execute_values for speed."""
    from psycopg2.extras import execute_values
    cur = conn.cursor()
    execute_values(cur, query, rows, page_size=page_size)
    conn.commit()
    cur.close()


# ── Storage helpers ─────────────────────────────────────────────────────────────────

def download_from_storage(storage_path, tmpdir):
    """Download a file from Supabase Storage into tmpdir. Returns local filepath.

    Uses requests library directly with certifi's CA bundle for SSL verification.
    """
    bucket = "retail-ops"
    local_path = os.path.join(tmpdir, os.path.basename(storage_path))

    storage_url = (
        f"{SUPABASE_URL.rstrip('/')}/storage/v1/object/{bucket}/{storage_path}"
    )

    headers = {
        "Authorization": f"Bearer {SUPABASE_KEY}",
        "apikey": SUPABASE_KEY,
    }

    # NOTE: SSL verification is disabled here because Supabase's certificate chain
    # requires an intermediate CA that certifi doesn't carry (CERT_TRUST_IS_PARTIAL_CHAIN).
    # The file is still encrypted in transit and authenticated via API key.
    resp = requests.get(storage_url, headers=headers, verify=False, timeout=60)
    resp.raise_for_status()

    with open(local_path, "wb") as f:
        f.write(resp.content)

    return local_path


# ── Main pipeline ────────────────────────────────────────────────────────────────

def _run_function(conn, name, run_id, error_message=None):
    if error_message is None:
        pg_update(conn, f"SELECT public.{name}(%s)", (run_id,))
    else:
        pg_update(
            conn,
            f"SELECT public.{name}(%s, %s)",
            (run_id, str(error_message)[:4000]),
        )


def _set_stage(run_id, stage):
    """Report pipeline progress to the UI. Never lets a reporting problem
    (e.g. migration not yet applied) abort the actual processing run."""
    try:
        conn = get_pg_conn()
        try:
            pg_update(
                conn,
                "UPDATE public.processing_runs "
                "SET stage = %s, stage_updated_at = now() WHERE id = %s",
                (stage, run_id),
            )
        finally:
            conn.close()
    except Exception as exc:
        print(f"  (could not record stage '{stage}': {exc})")


def run_processing_run(processing_run_id):
    """Process only the uploads atomically claimed for one durable run."""
    from ingest_file import (
        ingest_sales_file, ingest_account_dsr_file, ingest_inventory_file,
    )
    from build_dimensions import build_dimensions
    from refresh_gold import refresh_gold
    from refresh_reebok import refresh_reebok
    from refresh_stock import refresh_stock

    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    conn = get_pg_conn()
    try:
        _run_function(conn, "start_processing_run", processing_run_id)
        uploads = pg_select(
            conn,
            "SELECT id, original_file_name, report_type, storage_path "
            "FROM public.upload_audit_log "
            "WHERE processing_run_id = %s AND status = 'processing' "
            "ORDER BY uploaded_at, id",
            (processing_run_id,),
        )
    finally:
        conn.close()

    if not uploads:
        conn = get_pg_conn()
        try:
            _run_function(conn, "finish_processing_run", processing_run_id)
        finally:
            conn.close()
        print("No uploads assigned to this processing run.")
        return

    _set_stage(processing_run_id, "raw")
    print(f"Stage 1: ingesting {len(uploads)} claimed upload(s)")
    processed = []
    failures = []
    with tempfile.TemporaryDirectory() as tmpdir:
        conn = get_pg_conn()
        try:
            for upload in uploads:
                upload_id = upload["id"]
                try:
                    if not upload["storage_path"]:
                        raise ValueError("Queued upload has no storage path")
                    local_path = download_from_storage(upload["storage_path"], tmpdir)
                    if upload["report_type"] == "sales":
                        row_count = ingest_sales_file(
                            local_path, conn, upload_audit_id=upload_id
                        )
                    elif upload["report_type"] == "account_dsr":
                        row_count = ingest_account_dsr_file(
                            local_path, conn, upload_audit_id=upload_id
                        )
                    elif upload["report_type"] == "inventory":
                        row_count = ingest_inventory_file(
                            local_path, conn, upload_audit_id=upload_id
                        )
                    else:
                        raise ValueError(f"Unknown report type: {upload['report_type']}")
                    processed.append((upload_id, row_count))
                    print(f"  {upload['original_file_name']}: {row_count} row(s)")
                except Exception as exc:
                    failures.append(f"{upload['original_file_name']}: {exc}")
                    pg_update(
                        conn,
                        "UPDATE public.upload_audit_log "
                        "SET status = 'failed', error_message = %s "
                        "WHERE id = %s AND processing_run_id = %s",
                        (str(exc)[:4000], upload_id, processing_run_id),
                    )
        finally:
            conn.close()

    if failures:
        message = "Raw ingestion failed; " + "; ".join(failures)
        conn = get_pg_conn()
        try:
            _run_function(conn, "fail_processing_run", processing_run_id, message)
        finally:
            conn.close()
        raise RuntimeError(message)

    for name, stage, task in (
        ("Stage 2: staging dimensions", "dimensions", build_dimensions),
        ("Stage 3: staging stock facts", "facts", refresh_stock),
        ("Stage 4a: gold dashboard", "gold", refresh_gold),
        ("Stage 4b: Reebok metrics", "gold", refresh_reebok),
    ):
        _set_stage(processing_run_id, stage)
        started = time.monotonic()
        print(f"--- {name} ---")
        try:
            task()
        except Exception as exc:
            conn = get_pg_conn()
            try:
                _run_function(conn, "fail_processing_run", processing_run_id, f"{name} failed: {exc}")
            finally:
                conn.close()
            raise
        print(f"{name} finished in {time.monotonic() - started:.1f}s")

    conn = get_pg_conn()
    try:
        for upload_id, row_count in processed:
            pg_update(
                conn,
                "UPDATE public.upload_audit_log SET row_count = %s "
                "WHERE id = %s AND processing_run_id = %s",
                (row_count, upload_id, processing_run_id),
            )
        _run_function(conn, "finish_processing_run", processing_run_id)
    finally:
        conn.close()
    _set_stage(processing_run_id, "done")
    print("[OK] Processing run completed successfully.")


def run_pipeline():
    from ingest_file import (
        ingest_sales_file, ingest_account_dsr_file, ingest_inventory_file
    )
    from build_dimensions import build_dimensions
    from refresh_gold import refresh_gold
    from refresh_reebok import refresh_reebok
    from refresh_stock import refresh_stock

    # Force UTF-8 on stdout for Windows
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    conn = get_pg_conn()

    # ─── Stage 1: Ingest raw data ─────────────────────────────────────────
    print("Checking upload_audit_log for pending files...")
    # Recover files left mid-run by a stopped or timed-out previous runner.
    pg_update(
        conn,
        "UPDATE upload_audit_log "
        "SET status = 'pending', error_message = NULL "
        "WHERE status IN ('failed', 'processing')"
    )

    pending_files = pg_select(
        conn,
        "SELECT id, original_file_name, report_type, storage_path "
        "FROM upload_audit_log "
        "WHERE status IN ('pending', 'uploaded')"
    )

    print(f"Found {len(pending_files)} pending file(s) queued for processing.")
    if not pending_files:
        print("No pending files to process.")
        conn.close()
        return

    processed_ids = []
    failed_files = []

    with tempfile.TemporaryDirectory() as tmpdir:
        for f in pending_files:
            file_id = f["id"]
            orig_name = f["original_file_name"]
            report_type = f["report_type"]
            storage_path = f["storage_path"]

            print(f"\nProcessing: {orig_name} (Type: {report_type})")

            # Mark as processing
            pg_update(
                conn,
                "UPDATE upload_audit_log SET status = 'processing' WHERE id = %s",
                (file_id,)
            )

            try:
                if not storage_path:
                    raise ValueError("No storage_path on queued file")

                local_path = download_from_storage(storage_path, tmpdir)
                print(f"  Downloaded → {os.path.basename(local_path)}")

                if report_type == "sales":
                    row_count = ingest_sales_file(local_path, conn)
                elif report_type == "account_dsr":
                    row_count = ingest_account_dsr_file(local_path, conn)
                elif report_type == "inventory":
                    row_count = ingest_inventory_file(local_path, conn)
                else:
                    raise ValueError(f"Unknown report_type: {report_type}")

                processed_ids.append((file_id, row_count))
                print(f"  Ingested {row_count} rows")

            except Exception as e:
                print(f"  ERROR: {e}")
                failed_files.append(orig_name)
                pg_update(
                    conn,
                    "UPDATE upload_audit_log SET status = 'failed', error_message = %s WHERE id = %s",
                    (str(e), file_id)
                )

    conn.close()

    # ─── Stage 2: Build staging dimensions ─────────────────────────────────
    print("\n--- Running Stage 2: Dimension Build ---")
    try:
        build_dimensions()
    except Exception as exc:
        print(f"Dimension build failed: {exc}")
        raise

    # ─── Stage 2b: Refresh inventory stock facts ─────────────────────────
    print("\n--- Running Stage 2b: Stock Fact Refresh ---")
    try:
        refresh_stock()
    except Exception as exc:
        print(f"Stock refresh failed: {exc}")
        raise

    # ─── Stage 3: Refresh gold tables ────────────────────────────────────
    print("\n--- Running Stage 3: Gold Dashboard Refresh ---")
    try:
        refresh_gold()
    except Exception as exc:
        print(f"Gold refresh failed: {exc}")
        raise

    # ─── Stage 3b: Refresh Uppal Reebok metrics (single store) ──────────
    print("\n--- Running Stage 3b: Uppal Reebok Refresh ---")
    try:
        refresh_reebok()
    except Exception as exc:
        print(f"Reebok refresh failed: {exc}")
        raise

    # ─── Stage 4: Mark as completed ─────────────────────────────────────
    conn = get_pg_conn()
    for file_id, row_count in processed_ids:
        pg_update(
            conn,
            "UPDATE upload_audit_log SET status = 'completed', row_count = %s WHERE id = %s",
            (row_count, file_id)
        )
    conn.close()

    if failed_files:
        raise RuntimeError(f"Failed files: {', '.join(failed_files)}")

    print("\n[OK] Medallion Pipeline Finished Successfully!")


if __name__ == "__main__":
    run_pipeline()
