-- =============================================================
-- Asset Tracker — what each store physically has (fixtures, IT, furniture ...)
-- =============================================================
-- Built from docs/ASSET_TRACKER_GUIDE.md, on this application's own conventions.
--
--   public.asset_stores      the stores assets are kept for            (the guide's "stores")
--   public.asset_categories  groups of assets, e.g. Electronics        (master data)
--   public.asset_items       what can exist, e.g. Laptop, per category (master data)
--   public.store_assets      how many of an item a store has, with brand / specification / remark
--                            ONE row per store and item
--   public.asset_imports     one line per Excel import: who, when, which file, how many rows
--
-- No sample assets are inserted: categories and items are created by the first Excel import or
-- by adding an asset on the page. Names are matched without regard to case or extra spaces, so
-- "Office Chair" and "office  chair" are the same item.
--
-- Access: RLS on with no policies and nothing granted to anon / authenticated; only the server
-- routes (service_role) reach the tables, and they check the login and the admin role.
-- Safe to re-run.
-- =============================================================

CREATE TABLE IF NOT EXISTS public.asset_stores (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL CHECK (btrim(name) <> ''),
    code        text,                                   -- e.g. the site short name, R1157
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS asset_stores_name_key ON public.asset_stores ((lower(btrim(name))));
CREATE UNIQUE INDEX IF NOT EXISTS asset_stores_code_key ON public.asset_stores ((lower(btrim(code)))) WHERE code IS NOT NULL;

-- The one store the application runs for today.
INSERT INTO public.asset_stores (name, code)
SELECT 'Uppal Reebok', 'R1157'
WHERE NOT EXISTS (SELECT 1 FROM public.asset_stores WHERE lower(btrim(code)) = 'r1157' OR lower(btrim(name)) = 'uppal reebok');

CREATE TABLE IF NOT EXISTS public.asset_categories (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name           text NOT NULL CHECK (btrim(name) <> ''),
    display_order  integer NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS asset_categories_name_key ON public.asset_categories ((lower(btrim(name))));

CREATE TABLE IF NOT EXISTS public.asset_items (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id    uuid NOT NULL REFERENCES public.asset_categories(id) ON DELETE CASCADE,
    name           text NOT NULL CHECK (btrim(name) <> ''),
    display_order  integer NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS asset_items_category_name_key ON public.asset_items (category_id, (lower(btrim(name))));

CREATE TABLE IF NOT EXISTS public.store_assets (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id          uuid NOT NULL REFERENCES public.asset_stores(id) ON DELETE CASCADE,
    asset_item_id     uuid NOT NULL REFERENCES public.asset_items(id) ON DELETE RESTRICT,
    brand             text,
    specification     text,
    quantity          integer NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    remark            text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by_email  text,
    CONSTRAINT store_assets_store_item_key UNIQUE (store_id, asset_item_id)
);
CREATE INDEX IF NOT EXISTS store_assets_item_idx ON public.store_assets (asset_item_id);

CREATE TABLE IF NOT EXISTS public.asset_imports (
    id          bigserial PRIMARY KEY,
    store_id    uuid REFERENCES public.asset_stores(id) ON DELETE SET NULL,
    file_name   text,
    sheet_name  text,
    inserted    integer NOT NULL DEFAULT 0,
    updated     integer NOT NULL DEFAULT 0,
    by_email    text,
    at          timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.asset_stores     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asset_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asset_items      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_assets     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asset_imports    ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.asset_stores, public.asset_categories, public.asset_items, public.store_assets, public.asset_imports FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.asset_imports_id_seq FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.asset_stores, public.asset_categories, public.asset_items, public.store_assets, public.asset_imports TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.asset_imports_id_seq TO service_role;


-- ─── The item for a category name and an item name, creating either if it is new ────────────
CREATE OR REPLACE FUNCTION public.asset_item_for(p_category text, p_item text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_category text := btrim(regexp_replace(COALESCE(p_category, ''), '\s+', ' ', 'g'));
  v_item     text := btrim(regexp_replace(COALESCE(p_item, ''), '\s+', ' ', 'g'));
  v_category_id uuid;
  v_item_id     uuid;
BEGIN
  IF v_category = '' THEN RAISE EXCEPTION 'Category is missing'; END IF;
  IF v_item = '' THEN RAISE EXCEPTION 'Item name is missing'; END IF;

  INSERT INTO public.asset_categories (name, display_order)
  VALUES (v_category, (SELECT COALESCE(max(display_order), 0) + 1 FROM public.asset_categories))
  ON CONFLICT ((lower(btrim(name)))) DO NOTHING;
  SELECT id INTO v_category_id FROM public.asset_categories WHERE lower(btrim(name)) = lower(v_category);

  INSERT INTO public.asset_items (category_id, name, display_order)
  VALUES (v_category_id, v_item, (SELECT COALESCE(max(display_order), 0) + 1 FROM public.asset_items WHERE category_id = v_category_id))
  ON CONFLICT (category_id, (lower(btrim(name)))) DO NOTHING;
  SELECT id INTO v_item_id FROM public.asset_items WHERE category_id = v_category_id AND lower(btrim(name)) = lower(v_item);

  RETURN v_item_id;
END;
$$;


-- ─── Add ONE asset to a store. Fails if the store already has that item (edit it instead). ───
CREATE OR REPLACE FUNCTION public.asset_add(
    p_store uuid, p_category text, p_item text, p_brand text, p_specification text,
    p_quantity integer, p_remark text, p_email text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.asset_stores WHERE id = p_store) THEN RAISE EXCEPTION 'Store not found'; END IF;
  INSERT INTO public.store_assets (store_id, asset_item_id, brand, specification, quantity, remark, updated_by_email)
  VALUES (p_store, public.asset_item_for(p_category, p_item), NULLIF(btrim(p_brand), ''), NULLIF(btrim(p_specification), ''),
          COALESCE(p_quantity, 0), NULLIF(btrim(p_remark), ''), p_email)
  RETURNING id INTO v_id;   -- a duplicate raises unique_violation (23505) and nothing is kept
  RETURN v_id;
END;
$$;


-- ─── Excel import: all rows or none ─────────────────────────────────────────────────────────
-- p_rows: [{ "category", "item", "brand", "specification", "quantity", "remark" }, ...]
-- A row whose item the store already has UPDATES that row: the quantity is replaced, and brand /
-- specification / remark are replaced only when the file gives one (a blank cell keeps what is
-- saved). Any other row is INSERTED, creating its category and item if they are new.
CREATE OR REPLACE FUNCTION public.asset_import(
    p_store uuid, p_rows jsonb, p_file text, p_sheet text, p_email text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  r jsonb;
  v_new boolean;
  v_inserted integer := 0;
  v_updated  integer := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.asset_stores WHERE id = p_store) THEN RAISE EXCEPTION 'Store not found'; END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN RAISE EXCEPTION 'No rows to import'; END IF;

  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    INSERT INTO public.store_assets (store_id, asset_item_id, brand, specification, quantity, remark, updated_by_email)
    VALUES (p_store, public.asset_item_for(r->>'category', r->>'item'),
            NULLIF(btrim(r->>'brand'), ''), NULLIF(btrim(r->>'specification'), ''),
            COALESCE((r->>'quantity')::integer, 0), NULLIF(btrim(r->>'remark'), ''), p_email)
    ON CONFLICT (store_id, asset_item_id) DO UPDATE
      SET quantity = EXCLUDED.quantity,
          brand = COALESCE(EXCLUDED.brand, public.store_assets.brand),
          specification = COALESCE(EXCLUDED.specification, public.store_assets.specification),
          remark = COALESCE(EXCLUDED.remark, public.store_assets.remark),
          updated_at = now(), updated_by_email = EXCLUDED.updated_by_email
    RETURNING (xmax = 0) INTO v_new;
    IF v_new THEN v_inserted := v_inserted + 1; ELSE v_updated := v_updated + 1; END IF;
  END LOOP;

  INSERT INTO public.asset_imports (store_id, file_name, sheet_name, inserted, updated, by_email)
  VALUES (p_store, left(p_file, 200), left(p_sheet, 200), v_inserted, v_updated, p_email);

  RETURN jsonb_build_object('inserted', v_inserted, 'updated', v_updated);
END;
$$;

REVOKE ALL ON FUNCTION public.asset_item_for(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.asset_add(uuid, text, text, text, text, integer, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.asset_import(uuid, jsonb, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.asset_item_for(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.asset_add(uuid, text, text, text, text, integer, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.asset_import(uuid, jsonb, text, text, text) TO service_role;
