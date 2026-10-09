-- =============================================================
-- Petty Cash tracker (Uppal Reebok) — entries made in the app, with photos and admin approval
-- =============================================================
-- Builds on 2026_10_07_petty_cash.sql. Two sources of petty cash now sit side by side:
--
--   1. The Account DSR Excel ("Petty cash" worksheet) -> public.petty_cash_entries, replaced on
--      every Account DSR upload. Those lines are already spent and recorded by the store, so they
--      need no photo and no approval. All cash received (head office, sale cash) comes from here.
--   2. Entries the store manager makes in the app -> public.petty_cash_expenses (this file).
--      Each carries a photo of the debit voucher and of the receipt, and goes
--      draft -> submitted -> approved | rejected. Admin approves for Uppal.
--
-- Nothing below stores a balance. The page works them out:
--   actual    = Excel credits − Excel expenses − approved app entries
--   reserved  = submitted app entries (waiting for approval)
--   available = actual − reserved                      (so actual = available + reserved)
--   executed  = Excel expenses + approved app entries in the chosen period
--   refill    = max(target float − available, 0)
--
-- Access: as before, RLS on with no policies and nothing granted to anon / authenticated; only
-- the server routes (service_role) reach the tables and the photo bucket, and they enforce the
-- roles. Safe to re-run.
-- =============================================================

CREATE TABLE IF NOT EXISTS public.petty_cash_expenses (
    id                     bigserial PRIMARY KEY,
    store_site_short_name  text NOT NULL DEFAULT 'R1157',
    expense_date           date NOT NULL,
    category               text NOT NULL,
    amount                 numeric(12,2) NOT NULL CHECK (amount > 0),
    description            text NOT NULL DEFAULT '',
    voucher_path           text,          -- photo of the debit voucher (bucket petty-cash)
    receipt_path           text,          -- photo of the receipt / bill
    status                 text NOT NULL DEFAULT 'draft'
                           CHECK (status IN ('draft', 'submitted', 'approved', 'rejected')),
    rejection_reason       text,
    created_by             uuid,
    created_by_email       text,
    submitted_at           timestamptz,
    decided_by             uuid,
    decided_by_email       text,
    decided_at             timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    -- An entry cannot leave draft without both photos.
    CONSTRAINT petty_cash_expenses_photos CHECK (status = 'draft' OR (voucher_path IS NOT NULL AND receipt_path IS NOT NULL)),
    CONSTRAINT petty_cash_expenses_reason CHECK (status <> 'rejected' OR COALESCE(rejection_reason, '') <> '')
);

CREATE INDEX IF NOT EXISTS petty_cash_expenses_store_idx
    ON public.petty_cash_expenses (store_site_short_name, status, expense_date);

-- Who did what, when. Written by the trigger below, so it cannot be skipped by a route.
CREATE TABLE IF NOT EXISTS public.petty_cash_audit (
    id          bigserial PRIMARY KEY,
    expense_id  bigint,                 -- kept after the entry is deleted
    action      text NOT NULL,          -- draft_saved | submitted | approved | rejected | edited | deleted
    amount      numeric(12,2),
    actor_email text,
    remarks     text,
    at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.petty_cash_settings (
    store_site_short_name  text PRIMARY KEY,
    target_float           numeric(12,2) NOT NULL CHECK (target_float >= 0),
    updated_at             timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.petty_cash_settings (store_site_short_name, target_float)
VALUES ('R1157', 15000) ON CONFLICT (store_site_short_name) DO NOTHING;

CREATE OR REPLACE FUNCTION public.petty_cash_expenses_audit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    INSERT INTO public.petty_cash_audit (expense_id, action, amount, actor_email, remarks)
    VALUES (OLD.id, 'deleted', OLD.amount, OLD.created_by_email, 'was ' || OLD.status);
    RETURN OLD;
  END IF;
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.petty_cash_audit (expense_id, action, amount, actor_email)
    VALUES (NEW.id, CASE WHEN NEW.status = 'draft' THEN 'draft_saved' ELSE NEW.status END, NEW.amount, NEW.created_by_email);
    RETURN NEW;
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.petty_cash_audit (expense_id, action, amount, actor_email, remarks)
    VALUES (NEW.id, NEW.status, NEW.amount,
            CASE WHEN NEW.status IN ('approved', 'rejected') THEN NEW.decided_by_email ELSE NEW.created_by_email END,
            NEW.rejection_reason);
  ELSIF (NEW.amount, NEW.expense_date, NEW.category, NEW.description) IS DISTINCT FROM (OLD.amount, OLD.expense_date, OLD.category, OLD.description) THEN
    INSERT INTO public.petty_cash_audit (expense_id, action, amount, actor_email)
    VALUES (NEW.id, 'edited', NEW.amount, NEW.created_by_email);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS petty_cash_expenses_audit_trg ON public.petty_cash_expenses;
CREATE TRIGGER petty_cash_expenses_audit_trg
    AFTER INSERT OR UPDATE OR DELETE ON public.petty_cash_expenses
    FOR EACH ROW EXECUTE FUNCTION public.petty_cash_expenses_audit();

ALTER TABLE public.petty_cash_expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.petty_cash_audit    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.petty_cash_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.petty_cash_expenses, public.petty_cash_audit, public.petty_cash_settings FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.petty_cash_expenses_id_seq, public.petty_cash_audit_id_seq FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.petty_cash_expenses, public.petty_cash_audit, public.petty_cash_settings TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.petty_cash_expenses_id_seq, public.petty_cash_audit_id_seq TO service_role;
REVOKE ALL ON FUNCTION public.petty_cash_expenses_audit() FROM PUBLIC, anon, authenticated;


-- ─── Approve / reject, one entry or many, in ONE transaction ─────────────────────────────────
-- Only entries that are still 'submitted' change; anything already decided (or deleted) is left
-- alone and simply not counted, so two admins clicking at once cannot decide an entry twice.
-- The caller's identity comes from the server route (verified login), never from the browser.
CREATE OR REPLACE FUNCTION public.petty_cash_decide(
    p_ids bigint[], p_action text, p_reason text, p_user uuid, p_email text,
    p_store text DEFAULT 'R1157'
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_count integer;
BEGIN
  IF p_action NOT IN ('approved', 'rejected') THEN RAISE EXCEPTION 'Unknown action %', p_action; END IF;
  IF p_action = 'rejected' AND COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'A reason is needed to reject'; END IF;
  IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN RAISE EXCEPTION 'No entries selected'; END IF;

  UPDATE public.petty_cash_expenses
     SET status = p_action,
         rejection_reason = CASE WHEN p_action = 'rejected' THEN btrim(p_reason) END,
         decided_by = p_user, decided_by_email = p_email, decided_at = now(), updated_at = now()
   WHERE id = ANY (p_ids) AND store_site_short_name = p_store AND status = 'submitted';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.petty_cash_decide(bigint[], text, text, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.petty_cash_decide(bigint[], text, text, uuid, text, text) TO service_role;


-- ─── Photos: a private bucket, images only, 4 MB each ────────────────────────────────────────
-- No storage policies are added: with none, only service_role can read or write, and the page
-- gets short-lived signed links from a route that checks the login first.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('petty-cash', 'petty-cash', false, 4194304, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
  SET public = false, file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;
