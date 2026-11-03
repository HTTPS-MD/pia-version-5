-- An administrator can delete their own account, and only their own.
-- admin_delete_user() still refuses to remove an administrator, so nobody can remove another one.
-- The last administrator cannot be deleted. Safe to run more than once.
-- Run in the Supabase SQL editor.

create or replace function public.admin_delete_own_account() returns void
    language plpgsql security definer
    set search_path to 'public', 'extensions'
    as $$
declare
  v_email  text := lower(nullif(auth.jwt() ->> 'email', ''));
  v_admins int;
  r        record;
begin
  if v_email is null then
    raise exception 'PIA: sign in again to delete your account.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'admin' then
    raise exception 'PIA: only an administrator can use this.' using errcode = '42501';
  end if;

  -- Lock every admin row before counting, so two admins deleting themselves at once
  -- are handled one after the other and the last one is kept.
  perform 1 from public.profiles where lower(trim(role)) = 'admin' for update;
  select count(*) into v_admins from public.profiles where lower(trim(role)) = 'admin';
  if v_admins <= 1 then
    raise exception 'PIA: you are the last administrator and cannot delete your account.';
  end if;

  for r in
    select c.relname, a.attname
      from pg_attribute a
      join pg_class c     on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
       and not a.attisdropped
       and a.attname in ('student_email', 'user_email', 'participant_email')
  loop
    execute format('delete from public.%I where lower(%I) = $1', r.relname, r.attname)
      using v_email;
  end loop;

  delete from public.profiles where lower(email) = v_email;
  delete from auth.users      where lower(email) = v_email;
end;
$$;

revoke all on function public.admin_delete_own_account() from public;
grant execute on function public.admin_delete_own_account() to authenticated;
