-- =============================================================
-- Roles: admin / store_manager
-- =============================================================
-- public.users holds one row per Supabase Auth user, with the role that
-- controls what they can see. Checked server-side by requireAuth() in the
-- frontend's middleware/auth.js (never trust a client-side role alone).
--
-- store_site_short_name is which store a store_manager is scoped to
-- (matches gold table site_short_name, e.g. 'R1157' for Uppal Reebok).
-- NULL for admin (not scoped to one store).
--
-- This table does NOT create login accounts. After running this migration:
--   1. Supabase Dashboard -> Authentication -> Users -> Add user, for each
--      person (email + password), e.g. admin@thevirata.in, reebok@thevirata.in.
--   2. Run the INSERT template at the bottom of this file (edit the emails/
--      roles/store first) to give each one a role.
-- =============================================================

CREATE TABLE IF NOT EXISTS public.users (
    id                     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email                  text NOT NULL,
    role                   text NOT NULL CHECK (role IN ('admin', 'store_manager')),
    store_site_short_name  text,   -- NULL for admin; e.g. 'R1157' for a Reebok store_manager
    created_at             timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- A logged-in user can read their own row (the frontend needs this right after
-- login to know which role/interface to show). Nothing else is exposed.
DROP POLICY IF EXISTS users_select_own ON public.users;
CREATE POLICY users_select_own ON public.users
    FOR SELECT USING (auth.uid() = id);

GRANT SELECT ON public.users TO authenticated;
GRANT ALL ON public.users TO service_role;


-- ─── Run AFTER creating the auth users in the Dashboard (edit emails first) ──
-- insert into public.users (id, email, role, store_site_short_name)
-- select id, email, 'admin', null
-- from auth.users where email = 'admin@thevirata.in'
-- on conflict (id) do update set role = excluded.role, store_site_short_name = excluded.store_site_short_name;
--
-- insert into public.users (id, email, role, store_site_short_name)
-- select id, email, 'store_manager', 'R1157'
-- from auth.users where email = 'reebok@thevirata.in'
-- on conflict (id) do update set role = excluded.role, store_site_short_name = excluded.store_site_short_name;
