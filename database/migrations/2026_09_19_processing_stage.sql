-- Lets the worker report which pipeline stage a run is in, so the UI can tick
-- steps off in real time. Values written by the worker:
--   raw -> dimensions -> facts -> gold -> done
-- (NULL while a run is still queued waiting for a GitHub Actions runner.)
ALTER TABLE public.processing_runs
    ADD COLUMN IF NOT EXISTS stage text,
    ADD COLUMN IF NOT EXISTS stage_updated_at timestamptz;
