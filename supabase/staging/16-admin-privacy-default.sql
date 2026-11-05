-- Admin setting: "Start in Privacy Mode every time I sign in" (on by default), kept in the admin's account.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once.
-- It adds one small table and two functions. It does not touch profiles or any existing row.
--
-- Nobody can read or write the table through the API. An admin reads and changes only their own row,
-- through the two functions below. No row means the default: Privacy Mode on.
--
-- Rollback: drop function if exists public.admin_get_privacy_default(), public.admin_set_privacy_default(boolean);
--           drop table if exists public.admin_preferences;

create table if not exists public.admin_preferences (
  email           text        primary key,
  privacy_default boolean     not null default true,
  updated_at      timestamptz not null default now()
);

alter table public.admin_preferences enable row level security;
revoke all on public.admin_preferences from public, anon, authenticated;

create or replace function public.admin_get_privacy_default()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  return coalesce(
    (select p.privacy_default from public.admin_preferences p
      where p.email = lower(public.current_email())),
    true);
end;
$$;

create or replace function public.admin_set_privacy_default(p_on boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  if p_on is null then
    raise exception 'PIA: choose on or off.' using errcode = 'P0001';
  end if;
  insert into public.admin_preferences (email, privacy_default, updated_at)
  values (lower(public.current_email()), p_on, now())
  on conflict (email) do update
    set privacy_default = excluded.privacy_default, updated_at = now();
end;
$$;

revoke all on function public.admin_get_privacy_default() from public, anon;
revoke all on function public.admin_set_privacy_default(boolean) from public, anon;
grant execute on function public.admin_get_privacy_default() to authenticated;
grant execute on function public.admin_set_privacy_default(boolean) to authenticated;
