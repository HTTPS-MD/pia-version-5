-- PIA staging, step 2 of 2: the few rows and settings the app expects.
-- Run this ONLY in the PIA-Staging project, after 01-schema.sql.
-- Before running: in the staging dashboard, Authentication, Users, "Add user",
-- create the admin login (your email and a password). Tick "Auto Confirm User".

-- Live updates: the browser listens to changes on these tables.
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['profiles', 'settings', 'app_config', 'question_bank', 'tutoring_schedule'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- All three student stages start closed.
insert into public.settings (key, value) values
  ('stage_ocean', to_jsonb(false)),
  ('stage_char',  to_jsonb(false)),
  ('stage_dash',  to_jsonb(false))
on conflict (key) do nothing;

-- Default game rules.
insert into public.app_config (id) values (1) on conflict (id) do nothing;

-- A test section.
insert into public.sections (name)
select 'TEST-A' where not exists (select 1 from public.sections where name = 'TEST-A');

-- The admin profile, for the user you just created in Authentication.
insert into public.profiles (full_name, role, email, status)
select 'Staging Admin', 'admin', u.email, 'active'
from auth.users u
where not exists (select 1 from public.profiles p where lower(p.email) = lower(u.email))
order by u.created_at desc
limit 1;

select 'admin profiles: ' || count(*) as check_admin from public.profiles where role = 'admin';
