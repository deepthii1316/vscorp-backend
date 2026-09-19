import os
import sys
import argparse

# Ensure scripts folder is on sys.path
pipeline_dir = os.path.dirname(os.path.abspath(__file__))
scripts_dir = os.path.join(pipeline_dir, "scripts")
for p in [pipeline_dir, scripts_dir]:
    if p not in sys.path:
        sys.path.insert(0, p)

from scripts.run_pipeline import run_processing_run

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run one claimed VS Corp processing job")
    parser.add_argument("--run-id", default=os.environ.get("PROCESSING_RUN_ID"))
    args = parser.parse_args()
    if not args.run_id:
        parser.error("--run-id (or PROCESSING_RUN_ID) is required")
    run_processing_run(args.run_id)
