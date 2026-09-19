-- Durable, idempotent processing for the VS Corp upload pipeline.
-- Apply through the Supabase SQL editor / migration runner before deploying
-- the worker and frontend changes that use these objects.

BEGIN;

CREATE TABLE IF NOT EXISTS public.processing_runs (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    status          text NOT NULL CHECK (status IN ('queued', 'processing', 'completed', 'failed')),
    requested_at    timestamptz NOT NULL DEFAULT now(),
    started_at      timestamptz,
    completed_at    timestamptz,
    github_run_id   bigint,
    error_message   text,
    attempts        integer NOT NULL DEFAULT 0,
    created_by      uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_processing_runs_active
    ON public.processing_runs (requested_at DESC)
    WHERE status IN ('queued', 'processing');

ALTER TABLE public.upload_audit_log
    ADD COLUMN IF NOT EXISTS processing_run_id uuid REFERENCES public.processing_runs(id),
    ADD COLUMN IF NOT EXISTS attempt_count integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS processing_started_at timestamptz,
    ADD COLUMN IF NOT EXISTS completed_at timestamptz;

ALTER TABLE public.upload_audit_log
    DROP CONSTRAINT IF EXISTS upload_audit_log_status_check;
ALTER TABLE public.upload_audit_log
    ADD CONSTRAINT upload_audit_log_status_check
    CHECK (status IN ('queued', 'pending', 'uploaded', 'processing', 'success', 'completed', 'failed'));

CREATE INDEX IF NOT EXISTS idx_upload_audit_log_run
    ON public.upload_audit_log (processing_run_id, status);

-- Raw rows are owned by their upload. Re-running an upload must therefore be
-- a no-op rather than duplicating rows. Existing historical rows remain NULL
-- and are intentionally not altered by this migration.
ALTER TABLE raw.sales
    ADD COLUMN IF NOT EXISTS upload_audit_id uuid REFERENCES public.upload_audit_log(id),
    ADD COLUMN IF NOT EXISTS source_row_number integer;
ALTER TABLE raw.inventory
    ADD COLUMN IF NOT EXISTS upload_audit_id uuid REFERENCES public.upload_audit_log(id),
    ADD COLUMN IF NOT EXISTS source_row_number integer;
ALTER TABLE raw.account_dsr
    ADD COLUMN IF NOT EXISTS upload_audit_id uuid REFERENCES public.upload_audit_log(id),
    ADD COLUMN IF NOT EXISTS source_row_number integer;

CREATE UNIQUE INDEX IF NOT EXISTS uq_raw_sales_upload_row
    ON raw.sales (upload_audit_id, source_row_number)
    WHERE upload_audit_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_raw_inventory_upload_row
    ON raw.inventory (upload_audit_id, source_row_number)
    WHERE upload_audit_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_raw_account_dsr_upload_row
    ON raw.account_dsr (upload_audit_id, source_row_number)
    WHERE upload_audit_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_raw_sales_store_date
    ON raw.sales ("Store Number", "Bill Date");
CREATE INDEX IF NOT EXISTS idx_raw_sales_upload
    ON raw.sales (upload_audit_id);

CREATE TABLE IF NOT EXISTS public.report_email_deliveries (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    processing_run_id uuid REFERENCES public.processing_runs(id),
    report_type     text NOT NULL,
    report_date     date NOT NULL,
    recipient_group text NOT NULL,
    status          text NOT NULL CHECK (status IN ('queued', 'sending', 'sent', 'failed')),
    message_id      text,
    error_message   text,
    attempt_count   integer NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    sent_at         timestamptz,
    UNIQUE (report_type, report_date, recipient_group)
);

-- Atomically reserve queued uploads for one processing run. A second click
-- gets the existing active run instead of creating duplicate work.
CREATE OR REPLACE FUNCTION public.claim_processing_run(p_created_by uuid DEFAULT NULL)
RETURNS TABLE (run_id uuid, run_status text, upload_count integer, already_active boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    active_run public.processing_runs%ROWTYPE;
    new_run_id uuid;
    claimed_count integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('vs-corp-processing-run'));

    SELECT * INTO active_run
    FROM public.processing_runs
    WHERE status IN ('queued', 'processing')
    ORDER BY requested_at DESC
    LIMIT 1;

    IF FOUND THEN
        SELECT count(*) INTO claimed_count
        FROM public.upload_audit_log
        WHERE processing_run_id = active_run.id;
        RETURN QUERY SELECT active_run.id, active_run.status, claimed_count, true;
        RETURN;
    END IF;

    INSERT INTO public.processing_runs (status, created_by)
    VALUES ('queued', p_created_by)
    RETURNING id INTO new_run_id;

    WITH claimed AS (
        UPDATE public.upload_audit_log
        SET processing_run_id = new_run_id
        WHERE status IN ('queued', 'pending', 'uploaded')
          AND processing_run_id IS NULL
        RETURNING id
    )
    SELECT count(*) INTO claimed_count FROM claimed;

    IF claimed_count = 0 THEN
        UPDATE public.processing_runs
        SET status = 'completed', completed_at = now()
        WHERE id = new_run_id;
    END IF;

    RETURN QUERY SELECT new_run_id,
        CASE WHEN claimed_count = 0 THEN 'completed' ELSE 'queued' END,
        claimed_count,
        false;
END;
$$;

CREATE OR REPLACE FUNCTION public.start_processing_run(p_run_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.processing_runs
    SET status = 'processing', started_at = COALESCE(started_at, now()), attempts = attempts + 1,
        error_message = NULL
    WHERE id = p_run_id AND status = 'queued';

    UPDATE public.upload_audit_log
    SET status = 'processing', processing_started_at = now(), attempt_count = attempt_count + 1,
        error_message = NULL
    WHERE processing_run_id = p_run_id AND status IN ('queued', 'pending', 'uploaded');
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_processing_run(p_run_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.upload_audit_log
    SET status = 'completed', completed_at = now()
    WHERE processing_run_id = p_run_id AND status = 'processing';

    UPDATE public.processing_runs
    SET status = 'completed', completed_at = now(), error_message = NULL
    WHERE id = p_run_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_processing_run(p_run_id uuid, p_error_message text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.upload_audit_log
    SET status = 'failed', error_message = p_error_message
    WHERE processing_run_id = p_run_id AND status = 'processing';

    UPDATE public.processing_runs
    SET status = 'failed', completed_at = now(), error_message = p_error_message
    WHERE id = p_run_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.release_processing_run(p_run_id uuid, p_error_message text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.upload_audit_log
    SET status = 'queued', processing_run_id = NULL, error_message = p_error_message
    WHERE processing_run_id = p_run_id AND status IN ('queued', 'pending', 'uploaded');

    UPDATE public.processing_runs
    SET status = 'failed', completed_at = now(), error_message = p_error_message
    WHERE id = p_run_id;
END;
$$;

COMMIT;
