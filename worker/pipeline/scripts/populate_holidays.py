import os
import sys
import holidays
from datetime import date, timedelta
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()
supabase_url = os.environ.get("SUPABASE_URL")
supabase_key = os.environ.get("SUPABASE_KEY")

# Fallback: check inside reebok-app/.env.local
if not supabase_url or not supabase_key:
    from pathlib import Path
    env_local = Path(__file__).resolve().parent.parent / "reebok-app" / ".env.local"
    if env_local.exists():
        with open(env_local, "r") as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    if k == "NEXT_PUBLIC_SUPABASE_URL" and not supabase_url:
                        supabase_url = v
                    elif k == "SUPABASE_SERVICE_ROLE_KEY" and not supabase_key:
                        supabase_key = v

if not supabase_url or not supabase_key:
    print("Error: Supabase connection credentials not found in env.")
    sys.exit(1)


def populate_holidays():
    print("Generating holidays for India (TS and AP subdivisions)...")

    # Initialize holiday dictionaries for each subdivision from 2020 through 2030
    ts_holidays = holidays.India(years=range(2020, 2031), subdiv="TS")
    ap_holidays = holidays.India(years=range(2020, 2031), subdiv="AP")

    # Collect all unique holiday dates
    all_dates = sorted(list(set(list(ts_holidays.keys()) + list(ap_holidays.keys()))))

    records = []
    for dt in all_dates:
        names = []
        ts_name = ts_holidays.get(dt)
        if ts_name:
            names.append(f"{ts_name} (TS)")

        ap_name = ap_holidays.get(dt)
        if ap_name and ap_name != ts_name:
            names.append(f"{ap_name} (AP)")

        # Format combined description
        if ts_name == ap_name:
            holiday_desc = ts_name
        else:
            holiday_desc = " / ".join(names)

        records.append({
            "full_date": dt.isoformat(),
            "holiday_name": holiday_desc
        })

    print(f"Computed {len(records)} unique holiday dates across TS and AP.")

    # Initialize Supabase client
    supabase = create_client(supabase_url, supabase_key)

    # Truncate existing rows first to allow clean idempotency
    print("Clearing existing staging.holiday_reference data...")
    supabase.schema("staging").table("holiday_reference").delete().neq("holiday_name", "DUMMY_NONE").execute()

    # Batch insert into staging.holiday_reference
    BATCH_SIZE = 100
    print(f"Inserting into staging.holiday_reference in batches of {BATCH_SIZE}...")
    for i in range(0, len(records), BATCH_SIZE):
        batch = records[i:i+BATCH_SIZE]
        supabase.schema("staging").table("holiday_reference").insert(batch).execute()

    print("Holiday reference population completed successfully!")

    # Filter target dates matching dim_date range (2026-01-01 to 2030-12-31)
    target_dates = [r["full_date"] for r in records if r["full_date"] >= "2026-01-01"]
    print(f"Updating {len(target_dates)} holiday flags in staging.dim_date...")

    # Batch update to avoid URL query parameter length limits in HTTP request
    UPDATE_BATCH_SIZE = 50
    for i in range(0, len(target_dates), UPDATE_BATCH_SIZE):
        date_batch = target_dates[i:i+UPDATE_BATCH_SIZE]
        supabase.schema("staging").table("dim_date").update({"is_holiday": True}).in_("full_date", date_batch).execute()

    print("Completed updating is_holiday flag in dim_date!")


if __name__ == "__main__":
    populate_holidays()
