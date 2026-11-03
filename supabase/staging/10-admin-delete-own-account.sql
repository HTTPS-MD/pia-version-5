-- An administrator can delete their own account, and only their own.
-- admin_delete_user() still refuses to remove an administrator, so nobody can remove another one.
-- The last administrator cannot be deleted. Safe to run more than once.
-- Run in the Supabase SQL editor.

-- The profiles guard refused every administrator deletion. It now lets an administrator delete
-- their own row, but only from admin_delete_own_account() below, which marks the transaction.
CREATE OR REPLACE FUNCTION public.pia_admin_boundaries() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_actor   text := lower(nullif(auth.jwt() ->> 'email', ''));
  v_old_adm boolean := false;
  v_new_adm boolean := false;
  v_self    boolean := false;
begin
  if tg_op <> 'INSERT' then
    v_old_adm := lower(trim(coalesce(old.role, ''))) = 'admin';
    v_self    := v_actor is not null and lower(old.email) = v_actor;
  end if;
  if tg_op <> 'DELETE' then
    v_new_adm := lower(trim(coalesce(new.role, ''))) = 'admin';
  end if;

  -- No signed-in user: the project owner (SQL editor, service key). Anything
  -- goes, except that an administrator keeps at least two devices.
  if v_actor is null then
    if tg_op <> 'DELETE' then
      if v_new_adm and coalesce(new.max_devices, 1) < 2 then new.max_devices := 2; end if;
      return new;
    end if;
    return old;
  end if;

  if tg_op = 'DELETE' then
    -- Only the caller's own account, and only through admin_delete_own_account().
    if v_old_adm and not (v_self and current_setting('pia.self_delete', true) = 'on') then
      perform public.pia_refuse(v_actor, 'remove an administrator account', old.email);
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    -- "Add administrator" writes a NEW row; the limit floor applies to it.
    if v_new_adm and coalesce(new.max_devices, 1) < 2 then new.max_devices := 2; end if;
    return new;
  end if;

  -- UPDATE
  if v_old_adm and not v_self then
    if to_jsonb(new) is distinct from to_jsonb(old) then
      perform public.pia_refuse(v_actor, 'change another administrator''s account', old.email);
    end if;
    return new;
  end if;

  if v_old_adm and v_self then
    if not v_new_adm then
      perform public.pia_refuse(v_actor, 'change their own role', old.email);
    end if;
    if new.max_devices is distinct from old.max_devices
       and (new.max_devices is null or new.max_devices < 2 or new.max_devices > 10) then
      raise exception 'PIA: an administrator''s device limit must be between 2 and 10.' using errcode = '23514';
    end if;
    -- A direct write would leave the sign-in account on the old address.
    if current_user = 'authenticated' and new.email is distinct from old.email then
      perform public.pia_refuse(v_actor, 'change their own email here', old.email);
    end if;
    return new;
  end if;

  -- Not an admin row. Promotion makes a new administrator out of an existing
  -- participant or professor; new administrators come only from "Add
  -- administrator", which creates a fresh account.
  if v_new_adm then
    perform public.pia_refuse(v_actor, 'promote an existing account to administrator', old.email);
  end if;
  return new;
end;
$$;

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

  perform set_config('pia.self_delete', 'on', true);
  delete from public.profiles where lower(email) = v_email;
  delete from auth.users      where lower(email) = v_email;
end;
$$;

revoke all on function public.admin_delete_own_account() from public;
grant execute on function public.admin_delete_own_account() to authenticated;
