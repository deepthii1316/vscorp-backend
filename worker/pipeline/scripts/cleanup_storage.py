"""
cleanup_storage.py - remove the Reebok SALES and ACCOUNT DSR files from the retail-ops bucket
=============================================================================================
Step 3 of 3 of the data cleanup (see database/maintenance/2026_09_21_cleanup_*.sql).

Only these folders are touched:
    raw/sales
    raw/account-dsr
The inventory folder (raw/inventory) is deliberately left alone. The bucket and its folders stay.

Safe by default: without --execute it only LISTS what it would delete.

Usage (from worker/pipeline, with the venv python):
    .\\.venv\\Scripts\\python.exe scripts\\cleanup_storage.py              # list only
    .\\.venv\\Scripts\\python.exe scripts\\cleanup_storage.py --execute    # delete (asks you to type DELETE)

Reads NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from worker/pipeline/.env.
If your antivirus or proxy breaks HTTPS for Python ("certificate verify failed"), run
    .\\.venv\\Scripts\\python.exe -m pip install truststore
once (the script then uses the Windows certificate store), or delete the same two
folders by hand instead: Supabase dashboard -> Storage -> retail-ops -> raw -> sales / account-dsr ->
select all -> Delete.
"""

import argparse
import os
import sys
from pathlib import Path

import requests
from dotenv import load_dotenv

try:  # use the Windows certificate store when available (helps behind antivirus HTTPS scanning)
    import truststore
    truststore.inject_into_ssl()
except Exception:
    pass

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

BUCKET = "retail-ops"
DELETE_FOLDERS = ["raw/sales", "raw/account-dsr"]
KEEP_FOLDERS = ["raw/inventory"]          # listed for information only

URL = (os.environ.get("NEXT_PUBLIC_SUPABASE_URL") or "").rstrip("/")
KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or ""
if not URL or not KEY:
    raise SystemExit("Error: NEXT_PUBLIC_SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set in worker/pipeline/.env")

HEADERS = {"Authorization": f"Bearer {KEY}", "apikey": KEY, "Content-Type": "application/json"}


def list_folder(prefix):
    """All files directly inside a folder: [(path, size_bytes)]."""
    files, offset, page = [], 0, 100
    while True:
        res = requests.post(
            f"{URL}/storage/v1/object/list/{BUCKET}",
            headers=HEADERS,
            json={"prefix": prefix, "limit": page, "offset": offset, "sortBy": {"column": "name", "order": "asc"}},
            timeout=60,
        )
        res.raise_for_status()
        items = res.json()
        for it in items:
            if it.get("id"):                       # folders have no id
                files.append((f"{prefix}/{it['name']}", int((it.get("metadata") or {}).get("size") or 0)))
        if len(items) < page:
            return files
        offset += page


def delete_files(paths):
    deleted = 0
    for i in range(0, len(paths), 50):
        batch = paths[i:i + 50]
        res = requests.delete(f"{URL}/storage/v1/object/{BUCKET}", headers=HEADERS, json={"prefixes": batch}, timeout=120)
        res.raise_for_status()
        deleted += len(res.json()) if isinstance(res.json(), list) else len(batch)
    return deleted


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--execute", action="store_true", help="actually delete (default: list only)")
    args = ap.parse_args()

    to_delete = []
    for folder in DELETE_FOLDERS:
        files = list_folder(folder)
        mb = sum(s for _, s in files) / 1024 / 1024
        print(f"  {folder}: {len(files)} file(s), {mb:.2f} MB  -> WILL BE DELETED" if args.execute else f"  {folder}: {len(files)} file(s), {mb:.2f} MB  -> would be deleted")
        to_delete += [p for p, _ in files]
    for folder in KEEP_FOLDERS:
        files = list_folder(folder)
        print(f"  {folder}: {len(files)} file(s)  -> kept (not touched)")

    if not args.execute:
        print("\nList only. Nothing was deleted. Re-run with --execute to delete the files listed above.")
        return
    if not to_delete:
        print("\nNothing to delete.")
        return

    print(f"\nAbout to delete {len(to_delete)} file(s) from the '{BUCKET}' bucket.")
    if input("Type DELETE to confirm: ").strip() != "DELETE":
        print("Cancelled. Nothing was deleted.")
        return

    deleted = delete_files(to_delete)
    print(f"\nDeleted {deleted} file(s).")
    for folder in DELETE_FOLDERS + KEEP_FOLDERS:
        print(f"  {folder}: {len(list_folder(folder))} file(s) remaining")


if __name__ == "__main__":
    main()
