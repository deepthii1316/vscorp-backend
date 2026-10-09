-- =============================================================
-- Petty Cash (Uppal Reebok) — the store's cash book
-- =============================================================
-- Source: the "Petty cash" tab of the Account DSR workbook the store manager keeps
-- (DATE | VOUCHER NO | DESCRIPTION | EXPENSES | CREDIT | BALANCE), one running ledger.
--
--   * One row per ledger line. A line is money out (expense) or money in (credit).
--   * The balance is NEVER stored: it is always credits − expenses, in (entry_date, line_no)
--     order. The sheet's own BALANCE column is one row out of step, so it is not imported.
--   * credit_source splits money in: 'head_office' (cash handed to the store) vs 'sale_cash'
--     (till cash used for expenses — the DSR's "CASH USED" column).
--   * Uploading the workbook REPLACES the whole ledger in one transaction (the sheet is
--     cumulative) and logs the upload. Single lines are added / edited / deleted in the app.
--
-- Access: RLS on with no policies and no grants to anon / authenticated, so the browser key
-- cannot reach these tables. Only the server routes (service_role) do, and they enforce the
-- roles: admin = view only; store_manager = view, upload and edit (requireAuth in the frontend).
-- Safe to re-run.
-- =============================================================

CREATE TABLE IF NOT EXISTS public.petty_cash_entries (
    id                     bigserial PRIMARY KEY,
    store_site_short_name  text NOT NULL DEFAULT 'R1157',
    entry_date             date NOT NULL,
    line_no                integer NOT NULL,          -- order within the ledger (sheet order)
    voucher_no             text,
    description            text NOT NULL DEFAULT '',
    expense                numeric(12,2) NOT NULL DEFAULT 0 CHECK (expense >= 0),
    credit                 numeric(12,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    credit_source          text CHECK (credit_source IN ('head_office', 'sale_cash')),
    source                 text NOT NULL DEFAULT 'manual' CHECK (source IN ('upload', 'manual')),
    edited                 boolean NOT NULL DEFAULT false,   -- an uploaded line changed in the app
    created_by             uuid,
    updated_by             uuid,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT petty_cash_entries_has_amount CHECK (expense > 0 OR credit > 0)
);

CREATE INDEX IF NOT EXISTS petty_cash_entries_order_idx
    ON public.petty_cash_entries (store_site_short_name, entry_date, line_no);

CREATE TABLE IF NOT EXISTS public.petty_cash_uploads (
    id                     bigserial PRIMARY KEY,
    store_site_short_name  text NOT NULL DEFAULT 'R1157',
    file_name              text NOT NULL,
    sheet_title            text,
    line_count             integer NOT NULL,
    total_expense          numeric(14,2) NOT NULL,
    total_credit           numeric(14,2) NOT NULL,
    uploaded_by            uuid,
    uploaded_by_email      text,
    uploaded_at            timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.petty_cash_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.petty_cash_uploads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.petty_cash_entries, public.petty_cash_uploads FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.petty_cash_entries_id_seq, public.petty_cash_uploads_id_seq FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.petty_cash_entries, public.petty_cash_uploads TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.petty_cash_entries_id_seq, public.petty_cash_uploads_id_seq TO service_role;


-- ─── Upload: replace the whole ledger in ONE transaction ─────────────────────────────────────
-- p_rows: [{ "entry_date": "2026-06-20", "line_no": 1, "voucher_no": "1", "description": "...",
--            "expense": 1684, "credit": 0, "credit_source": null }]
-- Every existing line of the store is deleted first, including lines added or edited in the
-- app (the page warns about those before the upload is confirmed). All rows or none.
CREATE OR REPLACE FUNCTION public.petty_cash_replace(
    p_rows jsonb, p_file_name text, p_sheet_title text, p_user uuid, p_email text,
    p_store text DEFAULT 'R1157'
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_count integer;
  v_expense numeric;
  v_credit numeric;
BEGIN
  IF jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'No petty cash lines to import';
  END IF;

  DELETE FROM public.petty_cash_entries WHERE store_site_short_name = p_store;

  INSERT INTO public.petty_cash_entries
    (store_site_short_name, entry_date, line_no, voucher_no, description, expense, credit,
     credit_source, source, created_by, updated_by)
  SELECT p_store, (r->>'entry_date')::date, (r->>'line_no')::integer,
         NULLIF(r->>'voucher_no', ''), COALESCE(r->>'description', ''),
         COALESCE((r->>'expense')::numeric, 0), COALESCE((r->>'credit')::numeric, 0),
         NULLIF(r->>'credit_source', ''), 'upload', p_user, p_user
  FROM jsonb_array_elements(p_rows) r;

  SELECT count(*), COALESCE(sum(expense), 0), COALESCE(sum(credit), 0)
    INTO v_count, v_expense, v_credit
  FROM public.petty_cash_entries WHERE store_site_short_name = p_store;

  INSERT INTO public.petty_cash_uploads
    (store_site_short_name, file_name, sheet_title, line_count, total_expense, total_credit,
     uploaded_by, uploaded_by_email)
  VALUES (p_store, p_file_name, p_sheet_title, v_count, v_expense, v_credit, p_user, p_email);

  RETURN jsonb_build_object('lines', v_count, 'total_expense', v_expense, 'total_credit', v_credit);
END;
$$;

REVOKE ALL ON FUNCTION public.petty_cash_replace(jsonb, text, text, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.petty_cash_replace(jsonb, text, text, uuid, text, text) TO service_role;
