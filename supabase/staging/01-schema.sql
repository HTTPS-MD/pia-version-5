-- PIA staging, step 1 of 2: the structure of the real database (no student data).
-- Taken read-only from the real project. The old backup tables were left out.
-- Run this ONLY in the PIA-Staging project.

--
-- PostgreSQL database dump
--


-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.11 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--



--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: admin_attendance(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_attendance(p_section text) RETURNS TABLE(email text, present boolean, entered boolean, refused integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.pia_require_admin();
  return query
    select m.email, m.present, (m.entered_at is not null), m.refused_count
      from public.attendance_marks m
      join public.checkins c on c.id = m.checkin_id
     where c.section = trim(p_section) and c.stopped_at is null and c.ends_at > now();
end;
$$;


--
-- Name: admin_checkin_overview(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_checkin_overview() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.pia_require_admin();

  -- Housekeeping: nothing older than a day is of any use.
  delete from public.join_requests where created_at < now() - interval '1 day';
  delete from public.join_attempts where at < now() - interval '1 day';

  return jsonb_build_object(
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object(
               'section', s.section, 'students', s.n, 'without_number', s.missing, 'ocean_done', s.ocean) order by s.section)
        from (select trim(p.section) as section, count(*) as n,
                     count(*) filter (where sn.email is null) as missing,
                     count(*) filter (where coalesce(p.is_ocean_done, false)) as ocean
                from public.profiles p
                left join public.student_numbers sn on sn.email = lower(p.email)
               where lower(trim(coalesce(p.role, 'student'))) = 'student' and nullif(trim(p.section), '') is not null
               group by trim(p.section)) s), '[]'::jsonb),
    'open', coalesce((
      select jsonb_agg(jsonb_build_object('section', c.section, 'ends_at', c.ends_at) order by c.section)
        from public.checkins c where c.stopped_at is null and c.ends_at > now()), '[]'::jsonb),
    'waiting', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', w.id, 'section', w.section, 'full_name', w.full_name, 'created_at', w.created_at,
               'duplicate', w.dupes > 1) order by w.created_at)
        from (select r.id, r.section, p.full_name, r.created_at,
                     count(*) over (partition by r.email) as dupes
                from public.join_requests r
                left join public.profiles p on lower(p.email) = r.email
               where r.status = 'waiting' and r.created_at > now() - interval '20 minutes'
                 and exists (select 1 from public.checkins c
                              where c.section = r.section and c.stopped_at is null and c.ends_at > now())) w),
      '[]'::jsonb));
end;
$$;


--
-- Name: admin_create_auth_user(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_create_auth_user(target_email text, default_password text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
      begin
  perform public.pia_protect_admin_target(target_email, 'reset the sign-in account of');
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

        if public.pia_caller_role() is distinct from 'admin' then
          raise exception 'PIA: only an admin may call admin_create_auth_user().'
            using errcode = '42501';
        end if;
        perform public.admin_create_auth_user__inner(target_email, default_password);
      end;
      $$;


--
-- Name: admin_create_auth_user__inner(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_create_auth_user__inner(target_email text, default_password text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
BEGIN
  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    recovery_token,
    email_change_token_new,
    email_change_token_current,
    confirmation_token,
    email_change,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at
  )
  VALUES (
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(),
    'authenticated',
    'authenticated',
    target_email,
    crypt(default_password, gen_salt('bf')),
    now(),
    '',  
    '',  
    '',  
    '',  
    '',  -- explicitly empty email_change
    '{"provider":"email","providers":["email"]}',
    '{}',
    now(),
    now()
  );
END;
$$;


--
-- Name: admin_delete_section(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_delete_section(p_name text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_name text := trim(coalesce(p_name, ''));
begin
  perform public.pia_require_admin();
  if exists (select 1 from public.profiles where section = v_name and lower(trim(coalesce(role, 'student'))) = 'student') then
    raise exception 'This section still has students. Move them first.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.professor_sections where section = v_name) then
    raise exception 'A professor is assigned to this section.' using errcode = 'P0001';
  end if;
  delete from public.checkins        where section = v_name;
  delete from public.join_requests   where section = v_name;
  delete from public.stage_overrides where section = v_name;
  delete from public.sections        where name = v_name;
end;
$$;


--
-- Name: admin_delete_user(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_delete_user(target_email text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
      begin
  perform public.pia_protect_admin_target(target_email, 'remove');
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

        if public.pia_caller_role() is distinct from 'admin' then
          raise exception 'PIA: only an admin may call admin_delete_user().'
            using errcode = '42501';
        end if;
        perform public.admin_delete_user__inner(target_email);
      end;
      $$;


--
-- Name: admin_delete_user__inner(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_delete_user__inner(target_email text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $_$
declare
  v_email    text := lower(trim(target_email));
  v_caller   text := lower(auth.jwt() ->> 'email');
  v_is_admin boolean;
  v_admins   int;
  r          record;
begin
  if v_email is null or v_email = '' then
    raise exception 'PIA: an email address is required.' using errcode = '22023';
  end if;

  -- 0024: never the caller's own account. (No JWT -- the SQL editor -- has no
  -- caller, so this check does not apply there; the last-admin one does.)
  if v_caller is not null and v_email = v_caller then
    raise exception 'PIA: you cannot remove your own account. Ask another administrator to do it.';
  end if;

  -- 0024: lock every admin row before counting, so two admins removing each
  -- other at once are serialised -- the second waits for the first, then
  -- sees its removal.
  perform 1 from public.profiles where lower(trim(role)) = 'admin' for update;

  select exists (select 1 from public.profiles
                  where lower(email) = v_email and lower(trim(role)) = 'admin')
    into v_is_admin;

  if v_is_admin then
    select count(*) into v_admins from public.profiles where lower(trim(role)) = 'admin';
    if v_admins <= 1 then
      raise exception 'PIA: % is the last administrator and cannot be removed.', v_email;
    end if;
  end if;

  -- The caller may have been removed by another admin while this waited.
  if v_caller is not null and not exists (
       select 1 from public.profiles where lower(email) = v_caller and lower(trim(role)) = 'admin') then
    raise exception 'PIA: your administrator account no longer exists.' using errcode = '42501';
  end if;

  -- From here on, unchanged from 0021.
  delete from public.hint_consumptions where lower(student_email) = v_email;
  delete from public.problem_serves    where lower(student_email) = v_email;
  delete from public.math_attempt_log  where lower(student_email) = v_email;
  delete from public.tutoring_attempts where lower(student_email) = v_email;
  delete from public.ocean_submissions where lower(email)         = v_email;

  for r in
    select c.relname, a.attname
      from pg_attribute a
      join pg_class c     on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
       and not a.attisdropped
       and (a.attname in ('student_email', 'user_email', 'participant_email')
            or (c.relname = 'session_start_log' and a.attname = 'email'))
       and c.relname not in ('hint_consumptions', 'problem_serves',
                             'math_attempt_log', 'tutoring_attempts')
  loop
    execute format('delete from public.%I where lower(%I) = $1', r.relname, r.attname)
      using v_email;
  end loop;

  delete from public.profiles where lower(email) = v_email;
  delete from auth.users      where lower(email) = v_email;
end;
$_$;


--
-- Name: admin_grant_stage(text, text[], text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_grant_stage(p_stage text, p_emails text[] DEFAULT NULL::text[], p_section text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
      begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

        if public.pia_caller_role() is distinct from 'admin' then
          raise exception 'PIA: only an admin may call admin_grant_stage().'
            using errcode = '42501';
        end if;
        return (public.pia_record_stage_grant(p_stage, p_section, p_emails, (public.admin_grant_stage__inner(p_stage, p_emails, p_section))::jsonb))::jsonb;
      end;
      $$;


--
-- Name: admin_grant_stage__inner(text, text[], text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_grant_stage__inner(p_stage text, p_emails text[] DEFAULT NULL::text[], p_section text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
    v_target_stage text; v_granted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb; v_reason text; r record;
begin
    if not exists (select 1 from public.profiles where email = auth.jwt() ->> 'email' and lower(trim(role)) = 'admin') then
        raise exception 'Only an admin may grant stage access.';
    end if;

    v_target_stage := case p_stage when 'ocean' then 'OCEAN' when 'char' then 'Character Selection' when 'dash' then 'Tutoring Dashboard' else null end;
    if v_target_stage is null then raise exception 'Unknown stage key: %', p_stage; end if;
    if p_emails is null and p_section is null then raise exception 'Provide either p_emails or p_section.'; end if;

    for r in select email, is_ocean_done, selected_character, lower(trim(coalesce(group_type, ''))) as grp from public.profiles
             where coalesce(lower(trim(role)), 'student') = 'student' and ((p_emails is not null and email = any(p_emails)) or (p_section is not null and section = p_section)) loop
        v_reason := null;
        if p_stage = 'char' then
            if not coalesce(r.is_ocean_done, false) then v_reason := 'OCEAN test not yet completed.';
            elsif r.grp not in ('non-assigned', 'non_assigned') then v_reason := 'Group is not non-assigned -- character selection does not apply to them.'; end if;
        elsif p_stage = 'dash' then
            if not coalesce(r.is_ocean_done, false) then v_reason := 'OCEAN test not yet completed.';
            elsif r.grp in ('non-assigned', 'non_assigned') and r.selected_character is null then v_reason := 'Non-assigned but no character has been selected yet.'; end if;
        end if;

        if v_reason is not null then v_skipped := v_skipped || jsonb_build_object('email', r.email, 'reason', v_reason); continue; end if;

        if p_stage = 'ocean' then
            update public.profiles set is_ocean_done = false, current_stage = v_target_stage, stage_started_at = now() where email = r.email;
        elsif p_stage = 'char' then
            update public.profiles set selected_character = null, current_stage = v_target_stage, stage_started_at = now() where email = r.email;
        else 
            update public.profiles set current_stage = v_target_stage, stage_started_at = now() where email = r.email;
        end if;
        v_granted := v_granted || to_jsonb(r.email);
    end loop;
    return jsonb_build_object('granted', v_granted, 'skipped', v_skipped);
end;
$$;


--
-- Name: admin_import_student_numbers(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_import_student_numbers(p_rows jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  r record;
  v_count int := 0;
begin
  perform public.pia_require_admin();
  for r in select * from jsonb_to_recordset(p_rows) as x(email text, number text) loop
    perform public.admin_set_student_number(r.email, r.number);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;


--
-- Name: admin_let_back_in(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_let_back_in(p_section text, p_email text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.pia_require_admin();
  update public.attendance_marks m
     set entered_at = null, refused_count = 0
    from public.checkins c
   where c.id = m.checkin_id and c.section = trim(p_section)
     and c.stopped_at is null and c.ends_at > now()
     and m.email = lower(trim(coalesce(p_email, '')));
end;
$$;


--
-- Name: admin_let_in(uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_let_in(p_ids uuid[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_count int;
begin
  perform public.pia_require_admin();
  update public.join_requests r
     set status = 'let_in', let_in_at = now()
   where r.id = any (coalesce(p_ids, '{}'))
     and r.status = 'waiting'
     and r.created_at > now() - interval '20 minutes'
     and exists (select 1 from public.checkins c
                  where c.section = r.section and c.stopped_at is null and c.ends_at > now());
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


--
-- Name: admin_numbers_for(text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_numbers_for(p_emails text[]) RETURNS TABLE(email text, number text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.pia_require_admin();
  return query
    select sn.email, sn.number
      from public.student_numbers sn
     where sn.email in (select lower(trim(e)) from unnest(coalesce(p_emails, '{}')) as e);
end;
$$;


--
-- Name: admin_numbers_taken(text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_numbers_taken(p_numbers text[]) RETURNS TABLE(number_key text, full_name text, email text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.pia_require_admin();
  return query
    select sn.number_key, p.full_name, sn.email
      from public.student_numbers sn
      left join public.profiles p on lower(p.email) = sn.email
     where sn.number_key in (select public.pia_number_key(n) from unnest(coalesce(p_numbers, '{}')) as n);
end;
$$;


--
-- Name: admin_professor_sections(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_professor_sections() RETURNS TABLE(email text, section text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.pia_require_admin();
  return query select ps.email, ps.section from public.professor_sections ps order by ps.section;
end;
$$;


--
-- Name: admin_register_teacher(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_register_teacher(p_email text, p_name text, p_department text, p_assigned_section text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
      begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

        if public.pia_caller_role() is distinct from 'admin' then
          raise exception 'PIA: only an admin may call admin_register_teacher().'
            using errcode = '42501';
        end if;
        perform public.admin_register_teacher__inner(p_email, p_name, p_department, p_assigned_section);
      end;
      $$;


--
-- Name: admin_register_teacher__inner(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_register_teacher__inner(p_email text, p_name text, p_department text, p_assigned_section text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
begin
    if not exists (
        select 1 from public.profiles
        where email = auth.jwt() ->> 'email'
          and lower(trim(role)) = 'admin'
    ) then
        raise exception 'Only an admin may register faculty.';
    end if;

    insert into public.profiles (email, full_name, role, section, status)
    values (p_email, p_name, 'teacher', p_assigned_section, 'inactive')
    on conflict (email) do update
        set full_name = excluded.full_name,
            role      = 'teacher',
            section   = excluded.section;

    insert into public.professors (email, name, department, assigned_section, status)
    values (p_email, p_name, p_department, p_assigned_section, 'inactive')
    on conflict (email) do update
        set name             = excluded.name,
            department       = excluded.department,
            assigned_section = excluded.assigned_section;
end;
$$;


--
-- Name: admin_rename_section(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_rename_section(p_old text, p_new text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_old text := trim(coalesce(p_old, ''));
  v_new text := trim(coalesce(p_new, ''));
begin
  perform public.pia_require_admin();
  if v_new = '' then raise exception 'Type the new section name.' using errcode = 'P0001'; end if;
  if length(v_new) > 40 then raise exception 'Keep the name under 40 characters.' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.sections where name = v_old) then
    raise exception 'That section no longer exists.' using errcode = 'P0001';
  end if;
  if v_new = v_old then return; end if;
  if exists (select 1 from public.sections where lower(name) = lower(v_new) and name <> v_old) then
    raise exception 'A section with that name already exists.' using errcode = 'P0001';
  end if;
  update public.sections          set name = v_new             where name = v_old;
  update public.profiles          set section = v_new          where section = v_old;
  update public.professors        set assigned_section = v_new where assigned_section = v_old;
  update public.professor_sections set section = v_new         where section = v_old;
  update public.checkins          set section = v_new          where section = v_old;
  update public.join_requests     set section = v_new          where section = v_old;
  update public.stage_overrides   set section = v_new          where section = v_old;
end;
$$;


--
-- Name: admin_reset_password(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_reset_password(target_email text, new_password text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
      begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

        if public.pia_caller_role() is distinct from 'admin' then
          raise exception 'PIA: only an admin may call admin_reset_password().'
            using errcode = '42501';
        end if;
        perform public.admin_reset_password__inner(target_email, new_password);
      end;
      $$;


--
-- Name: admin_reset_password__inner(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_reset_password__inner(target_email text, new_password text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
DECLARE
  existing_user_id uuid;
BEGIN
  -- Subukang i-update ang password kung nag-e-exist na sa auth.users
  UPDATE auth.users
  SET 
    encrypted_password = crypt(new_password, gen_salt('bf')),
    updated_at = now()
  WHERE email = target_email
  RETURNING id INTO existing_user_id;

  -- Kung wala pang auth account (kasi pre-registered lang), gawan natin ngayon lang
  IF existing_user_id IS NULL THEN
    existing_user_id := gen_random_uuid();
    
    INSERT INTO auth.users (
      id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) VALUES (
      existing_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', target_email, crypt(new_password, gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()
    );
    
    INSERT INTO auth.identities (
      provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at, id
    ) VALUES (
      existing_user_id::text, existing_user_id, format('{"sub":"%s","email":"%s"}', existing_user_id::text, target_email)::jsonb, 'email', now(), now(), now(), gen_random_uuid()
    );

    -- I-sync ang id sa profiles table kung meron man
    UPDATE public.profiles SET id = existing_user_id WHERE email = target_email;
  END IF;
END;
$$;


--
-- Name: admin_revoke_device(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_revoke_device(p_email text, p_device_id text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $_$
declare
  v_devices text[];
  v_map     jsonb;
  v_new     text[];
  v_gone    text[];
  v_uid     uuid;
  v_sids    uuid[] := '{}';
  v_ended   int := 0;
  v_unbound int := 0;
  d         text;
  s         text;
begin
  perform public.pia_protect_admin_target(p_email, 'revoke the devices of');
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'admin' then
    raise exception 'PIA: only an admin can revoke a device.' using errcode = '42501';
  end if;

  select coalesce(p.active_devices, '{}'), coalesce(p.device_sessions, '{}'::jsonb)
    into v_devices, v_map
    from public.profiles p
   where p.email = p_email
     for update;

  if not found then
    raise exception 'PIA: no profile for %', p_email using errcode = '22023';
  end if;

  if p_device_id is null then
    v_gone := v_devices;
    v_new  := '{}';
  else
    v_gone := array(select x from unnest(v_devices) x where x = p_device_id);
    v_new  := array(select x from unnest(v_devices) x where x is distinct from p_device_id);
  end if;

  -- The session behind each removed device, where one was recorded.
  foreach d in array v_gone loop
    s := v_map ->> d;
    if s ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      v_sids := array_append(v_sids, s::uuid);
    else
      v_unbound := v_unbound + 1;
    end if;
    v_map := v_map - d;
  end loop;

  -- End them. Scoped to this account's own sessions, so a wrong id in the map
  -- can never sign anybody else out.
  select u.id into v_uid from auth.users u where lower(u.email) = lower(p_email) limit 1;

  if v_uid is not null and coalesce(array_length(v_sids, 1), 0) > 0 then
    with gone as (
      delete from auth.sessions where id = any(v_sids) and user_id = v_uid returning 1
    )
    select count(*) into v_ended from gone;

    delete from auth.refresh_tokens where session_id = any(v_sids) and user_id = v_uid::text;
  end if;

  update public.profiles
     set active_devices = v_new, device_sessions = v_map
   where email = p_email;

  return jsonb_build_object(
    'devices',        v_new,
    'removed',        coalesce(array_length(v_gone, 1), 0),
    'sessions_ended', v_ended,
    'unbound',        v_unbound);
end;
$_$;


--
-- Name: admin_revoke_sessions(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_revoke_sessions(p_email text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
      begin
  perform public.pia_protect_admin_target(p_email, 'sign out');
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

        if public.pia_caller_role() is distinct from 'admin' then
          raise exception 'PIA: only an admin may call admin_revoke_sessions().'
            using errcode = '42501';
        end if;
        perform public.admin_revoke_sessions__inner(p_email);
      end;
      $$;


--
-- Name: admin_revoke_sessions__inner(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_revoke_sessions__inner(p_email text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
begin
    if not exists (select 1 from public.profiles where email = auth.jwt() ->> 'email' and lower(trim(role)) = 'admin') then
        raise exception 'Only an admin may revoke sessions.';
    end if;
    update public.profiles set sessions_revoked_at = now(), active_devices = '{}' where email = p_email;

    -- End the sessions themselves, not just the tokens' standing: without a
    -- refresh token the revoked browser cannot mint a new access token that
    -- would pass jwt_is_current(). Refresh tokens cascade with their session;
    -- the second delete catches any legacy token that was never tied to one.
    delete from auth.sessions
     where user_id in (select u.id from auth.users u where lower(u.email) = lower(p_email));
    delete from auth.refresh_tokens
     where user_id in (select u.id::text from auth.users u where lower(u.email) = lower(p_email));
end;
$$;


--
-- Name: admin_revoke_stage(text, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_revoke_stage(p_stage text, p_sections text[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_label    text;
  v_sections text[];
  v_moved    int := 0;
  v_cleared  int := 0;
begin
  if public.pia_caller_role() is distinct from 'admin' or not public.jwt_is_current() then
    raise exception 'PIA: only an administrator can revoke a stage.' using errcode = '42501';
  end if;

  if p_stage is null or p_stage not in ('ocean', 'char', 'dash') then
    raise exception 'PIA: unknown stage key: %', coalesce(p_stage, '(null)') using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct s), '{}') into v_sections
    from (select nullif(trim(x), '') as s from unnest(coalesce(p_sections, '{}')) x) t
   where s is not null;

  if coalesce(array_length(v_sections, 1), 0) = 0 then
    raise exception 'PIA: choose at least one section to revoke.' using errcode = '22023';
  end if;

  if public.pia_stage_open('stage_' || p_stage) then
    raise exception 'PIA: this stage is open for every section. Close it for everyone first; it cannot be revoked one section at a time.'
      using errcode = 'P0001';
  end if;

  v_label := case p_stage when 'ocean' then 'OCEAN'
                          when 'char'  then 'Character Selection'
                          else 'Tutoring Dashboard' end;

  with gone as (
    delete from public.stage_overrides
     where stage = p_stage and section = any (v_sections)
    returning 1)
  select count(*) into v_cleared from gone;

  with moved as (
    update public.profiles
       set current_stage = 'Waiting Room', stage_started_at = now()
     where current_stage = v_label
       and section = any (v_sections)
       and lower(trim(coalesce(role, 'student'))) = 'student'
    returning 1)
  select count(*) into v_moved from moved;

  return jsonb_build_object('stage', p_stage, 'sections', to_jsonb(v_sections),
                            'cleared', v_cleared, 'moved', v_moved);
end;
$$;


--
-- Name: admin_section_students(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_section_students(p_section text) RETURNS TABLE(email text, full_name text, number text, group_type text, current_stage text, status text, is_ocean_done boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.pia_require_admin();
  return query
    select p.email, p.full_name, sn.number, p.group_type, p.current_stage, p.status,
           coalesce(p.is_ocean_done, false)
      from public.profiles p
      left join public.student_numbers sn on sn.email = lower(p.email)
     where trim(p.section) = trim(p_section)
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
       and p.email is not null
     order by lower(p.full_name);
end;
$$;


--
-- Name: admin_set_attendance(text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_attendance(p_section text, p_email text, p_present boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_id    uuid;
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  perform public.pia_require_admin();
  select c.id into v_id from public.checkins c
   where c.section = trim(p_section) and c.stopped_at is null and c.ends_at > now();
  if v_id is null then
    raise exception 'Attendance is not open for this section.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profiles p
                  where lower(p.email) = v_email and trim(p.section) = trim(p_section)
                    and lower(trim(coalesce(p.role, 'student'))) = 'student') then
    raise exception 'That student is not in this section.' using errcode = 'P0001';
  end if;
  if p_present is null then
    delete from public.attendance_marks where checkin_id = v_id and email = v_email;
  else
    insert into public.attendance_marks (checkin_id, email, present)
    values (v_id, v_email, p_present)
    on conflict (checkin_id, email) do update set present = excluded.present, marked_at = now();
  end if;
end;
$$;


--
-- Name: admin_set_section_professor(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_section_professor(p_section text, p_email text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_section text := trim(coalesce(p_section, ''));
  v_email   text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_old     text;
begin
  perform public.pia_require_admin();
  if not exists (select 1 from public.sections where name = v_section) then
    raise exception 'That section no longer exists.' using errcode = 'P0001';
  end if;
  if v_email is not null and not exists (select 1 from public.professors where lower(email) = v_email) then
    raise exception 'That professor was not found.' using errcode = 'P0001';
  end if;
  select ps.email into v_old from public.professor_sections ps where ps.section = v_section;
  delete from public.professor_sections where section = v_section;
  if v_email is not null then
    insert into public.professor_sections (email, section) values (v_email, v_section);
  end if;
  if v_old is not null then perform public.pia_sync_professor(v_old); end if;
  if v_email is not null then perform public.pia_sync_professor(v_email); end if;
end;
$$;


--
-- Name: admin_set_stage_open(text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_stage_open(p_stage text, p_open boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $_$
declare
  v_label    text;
  v_evicted  int := 0;
  v_valtype  text;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

  if public.pia_caller_role() <> 'admin' then
    raise exception 'PIA: only an admin can open or close a stage.' using errcode = '42501';
  end if;

  if p_stage not in ('ocean', 'char', 'dash') then
    raise exception 'PIA: unknown stage key: %', coalesce(p_stage, '(null)') using errcode = '22023';
  end if;

  v_label := case p_stage when 'ocean' then 'OCEAN'
                          when 'char'  then 'Character Selection'
                          else 'Tutoring Dashboard' end;

  -- Ang settings.value ay maaaring jsonb o boolean depende sa kung paano ito
  -- unang nagawa. Dumadaan sa text cast para gumana sa dalawa.
  select atttypid::regtype::text into v_valtype
    from pg_attribute
   where attrelid = 'public.settings'::regclass and attname = 'value';

  execute format(
    'insert into public.settings (key, value) values ($1, $2::%s)
       on conflict (key) do update set value = excluded.value', v_valtype)
    using 'stage_' || p_stage, case when p_open then 'true' else 'false' end;

  if not p_open then
    with evicted as (
      update public.profiles
         set current_stage = 'Waiting Room', stage_started_at = now()
       where current_stage = v_label
         and lower(trim(coalesce(role, 'student'))) = 'student'
      returning 1)
    select count(*) into v_evicted from evicted;
  end if;

  return jsonb_build_object('stage', p_stage, 'open', p_open, 'evicted', v_evicted);
end;
$_$;


--
-- Name: admin_set_student_number(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_student_number(p_email text, p_number text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  v_key   text := public.pia_number_key(p_number);
  v_owner text;
begin
  perform public.pia_require_admin();
  if v_key !~ '^[0-9]{11}$' then
    raise exception 'PIA: a student number has 11 digits.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profiles where lower(email) = lower(trim(p_email))) then
    raise exception 'PIA: no student is registered with that email.' using errcode = 'P0002';
  end if;

  select sn.email into v_owner
    from public.student_numbers sn
   where sn.number_key = v_key and sn.email <> lower(trim(p_email));
  if v_owner is not null then
    raise exception 'PIA: that number already belongs to another student (%).', v_owner using errcode = 'P0001';
  end if;

  insert into public.student_numbers (email, number_key, number)
  values (lower(trim(p_email)), v_key, trim(p_number))
  on conflict (email) do update set number_key = excluded.number_key, number = excluded.number, updated_at = now();
end;
$_$;


--
-- Name: admin_set_tutoring_schedule(text, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_tutoring_schedule(p_section text, p_opens timestamp with time zone, p_closes timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_section text := nullif(trim(coalesce(p_section, '')), '');
begin
  if public.pia_caller_role() is distinct from 'admin' or not public.jwt_is_current() then
    raise exception 'PIA: only an administrator can set the tutoring schedule.' using errcode = '42501';
  end if;
  if v_section is null then
    raise exception 'PIA: choose a section.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where nullif(trim(section), '') = v_section) then
    raise exception 'PIA: unknown section: %', v_section using errcode = '22023';
  end if;

  if p_opens is null and p_closes is null then
    delete from public.tutoring_schedule where section = v_section;
    return jsonb_build_object('section', v_section, 'opens_at', null, 'closes_at', null);
  end if;

  if p_closes is not null and p_closes <= now() then
    raise exception 'PIA: the end must be in the future.' using errcode = '22023';
  end if;
  if p_opens is not null and p_closes is not null and p_closes <= p_opens then
    raise exception 'PIA: the end must be after the start.' using errcode = '22023';
  end if;

  insert into public.tutoring_schedule (section, opens_at, closes_at, set_by, set_at)
  values (v_section, p_opens, p_closes, lower(nullif(auth.jwt() ->> 'email', '')), now())
  on conflict (section) do update
    set opens_at = excluded.opens_at, closes_at = excluded.closes_at,
        set_by = excluded.set_by, set_at = excluded.set_at;

  return jsonb_build_object('section', v_section, 'opens_at', p_opens, 'closes_at', p_closes);
end;
$$;


--
-- Name: admin_start_checkin(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_start_checkin(p_section text, p_minutes integer DEFAULT 15) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_section text := trim(p_section);
  v_id      uuid;
begin
  perform public.pia_require_admin();
  if nullif(v_section, '') is null then
    raise exception 'PIA: choose a section.' using errcode = 'P0001';
  end if;
  if p_minutes is null or p_minutes < 5 or p_minutes > 120 then
    raise exception 'PIA: check-in stays open between 5 and 120 minutes.' using errcode = 'P0001';
  end if;

  update public.checkins set stopped_at = now() where section = v_section and stopped_at is null;
  insert into public.checkins (section, ends_at, started_by)
  values (v_section, now() + make_interval(mins => p_minutes), public.current_email())
  returning id into v_id;
  return v_id;
end;
$$;


--
-- Name: admin_stop_checkin(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_stop_checkin(p_section text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.pia_require_admin();
  update public.checkins set stopped_at = now() where section = trim(p_section) and stopped_at is null;
end;
$$;


--
-- Name: admin_students_with_numbers(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_students_with_numbers(p_section text) RETURNS TABLE(email text, full_name text, number text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform public.pia_require_admin();
  return query
    select p.email, p.full_name, sn.number
      from public.profiles p
      left join public.student_numbers sn on sn.email = lower(p.email)
     where trim(p.section) = trim(p_section)
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
       and p.email is not null
     order by p.full_name;
end;
$$;


--
-- Name: check_math_answer(uuid, text, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_math_answer(p_session_id uuid, p_problem_id text, p_submitted numeric) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    MAX_ATTEMPTS constant int := 2; MAX_PER_PROBLEM_DAY constant int := 10; MAX_PER_MINUTE constant int := 15; MAX_PROBLEMS_PER_SESS constant int := 10;
    v_email text := auth.jwt() ->> 'email'; v_key numeric; v_used int; v_already boolean; v_n int; v_correct boolean;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

    if v_email is null then raise exception 'Not authenticated.'; end if;

    select count(*) into v_n from public.math_attempt_log where student_email = v_email and attempted_at > now() - interval '1 minute';
    if v_n >= MAX_PER_MINUTE then raise exception 'Answers are coming in too quickly. Please slow down.' using errcode = 'P0001'; end if;

    select count(*) into v_n from public.math_attempt_log where student_email = v_email and problem_id = p_problem_id and attempted_at > now() - interval '24 hours';
    if v_n >= MAX_PER_PROBLEM_DAY then raise exception 'Daily attempt limit reached for this problem.' using errcode = 'P0001'; end if;

    select count(distinct problem_id) into v_n from public.math_attempt_log where student_email = v_email and session_id = p_session_id and problem_id <> p_problem_id;
    if v_n >= MAX_PROBLEMS_PER_SESS then raise exception 'This session has already ended.' using errcode = 'P0001'; end if;

    select answer into v_key from public.math_answers where problem_id = p_problem_id;
    if not found then raise exception 'Unknown problem_id: %', p_problem_id; end if;

    select count(*), coalesce(bool_or(was_correct), false) into v_used, v_already from public.math_attempt_log where student_email = v_email and session_id = p_session_id and problem_id = p_problem_id;
    if v_already or v_used >= MAX_ATTEMPTS then return jsonb_build_object('correct', false, 'attempts_used', v_used, 'attempts_left', 0, 'locked', true); end if;

    v_correct := (p_submitted = v_key);
    insert into public.math_attempt_log (student_email, problem_id, session_id, was_correct) values (v_email, p_problem_id, p_session_id, v_correct);
    v_used := v_used + 1;
    return jsonb_build_object('correct', v_correct, 'attempts_used', v_used, 'attempts_left', greatest(0, MAX_ATTEMPTS - v_used), 'locked', v_correct or v_used >= MAX_ATTEMPTS);
end;
$$;


--
-- Name: check_question_answer(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_question_answer(p_session_id uuid, p_problem_id text, p_submitted text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_sub     text := left(trim(coalesce(p_submitted, '')), 60);
  v_sq      public.served_questions%rowtype;
  v_used    int;
  v_ok      boolean;
  v_correct boolean;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if v_sub = '' then
    raise exception 'PIA: an answer is required.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  if not found then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  select count(*), coalesce(bool_or(was_correct), false) into v_used, v_ok
    from public.question_attempts
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  -- Closed: solved, both tries used, or already recorded. Nothing is checked.
  if v_ok or v_used >= 2 or exists (
       select 1 from public.tutoring_attempts t
        where t.session_id = p_session_id and t.student_email = v_email and t.problem_id = p_problem_id) then
    return jsonb_build_object('correct', v_ok, 'attempts_used', v_used, 'attempts_left', 0, 'locked', true);
  end if;

  v_correct := public.pia_answer_matches(v_sub, v_sq.final_answer);

  insert into public.question_attempts (session_id, student_email, problem_id, attempt_number, submitted, was_correct)
  values (p_session_id, v_email, p_problem_id, v_used + 1, v_sub, v_correct);

  return jsonb_build_object(
    'correct',       v_correct,
    'attempts_used', v_used + 1,
    'attempts_left', case when v_correct then 0 else greatest(1 - v_used, 0) end,
    'locked',        v_correct or v_used + 1 >= 2);
end;
$$;


--
-- Name: check_step_answer(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_step_answer(p_session_id uuid, p_problem_id text, p_submitted text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email    text;
  v_sub      text := left(trim(coalesce(p_submitted, '')), 60);
  v_sq       public.served_questions%rowtype;
  v_st       public.step_states%rowtype;
  v_required int;
  v_step     jsonb;
  v_key      numeric;
  v_kind     text;
  v_idx      int;
  v_stage    text;
  v_num      numeric;
  v_outcome  text;
  v_text     text;
  v_confirm  text;
  v_w        public.game_windows%rowtype;
begin
  v_email := public.pia_game_email();
  if v_sub = '' then
    raise exception 'PIA: an answer is required.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  select * into v_st from public.step_states
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
   for update;
  if v_sq.problem_id is null or v_st.problem_id is null then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  v_w := public.pia_game_window(p_session_id, v_email);

  if v_st.completed
     or exists (select 1 from public.tutoring_attempts t
                 where t.session_id = p_session_id and t.student_email = v_email and t.problem_id = p_problem_id) then
    return jsonb_build_object('outcome', 'locked', 'state', public.pia_step_state_json(v_sq, v_st),
                              'clock', public.pia_clock_json(v_w));
  end if;

  -- The session time limit has passed: nothing more is checked or counted.
  if public.pia_window_expired(v_w) then
    return jsonb_build_object('outcome', 'time_expired', 'state', public.pia_step_state_json(v_sq, v_st),
                              'clock', public.pia_clock_json(v_w));
  end if;

  v_required := public.pia_step_required(v_sq.topic);
  v_idx      := v_st.step_index;
  v_stage    := v_st.stage;
  v_step     := v_sq.steps -> v_idx;
  v_kind     := public.pia_step_confirm_kind(v_sq.topic, v_idx);
  v_key      := public.pia_eval_expr(coalesce(v_step ->> 'answer', v_step ->> 'stepAnswer', ''));

  if v_stage = 'work' then
    if not public.pia_step_matches(v_sub, coalesce(v_step ->> 'answer', v_step ->> 'stepAnswer', '')) then
      v_outcome := 'wrong';
    elsif not public.pia_has_working(v_sub) and public.pia_is_final_format(v_kind, v_sub) then
      v_outcome := 'step_done';
      v_num     := public.pia_eval_expr(v_sub);
      v_text    := public.pia_format_final(v_kind, v_num);
    else
      -- Right value, but working or not in the final shape: ask for the value.
      v_outcome := 'needs_final';
    end if;
  else
    if public.pia_is_final_format(v_kind, v_sub) then
      v_num := public.pia_eval_expr(v_sub);
    end if;
    if v_num is not null and v_key is not null and abs(v_num - v_key) <= 0.001 then
      v_outcome := 'step_done';
      v_text    := coalesce(v_st.work_text, public.pia_format_final(v_kind, v_num));
      v_confirm := public.pia_format_final(v_kind, v_num);
    else
      v_outcome := 'format_error';
    end if;
  end if;

  insert into public.step_events (session_id, student_email, problem_id, step_index, stage, submitted, outcome)
  values (p_session_id, v_email, p_problem_id, v_idx, v_stage, v_sub,
          case when v_outcome = 'step_done' and v_idx + 1 >= v_required then 'question_done' else v_outcome end);

  if v_outcome in ('wrong', 'format_error') then
    update public.step_states
       set errors = errors + 1,
           wrong_streak = wrong_streak + 1,
           hint_unlocked = hint_unlocked or (wrong_streak + 1 >= 2),
           updated_at = now()
     where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
     returning * into v_st;

  elsif v_outcome = 'needs_final' then
    update public.step_states
       set stage = 'confirm', work_text = v_sub, wrong_streak = 0, hint_tier = 0,
           hint_unlocked = false, updated_at = now()
     where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
     returning * into v_st;

  else  -- step_done
    update public.step_states
       set done_steps = done_steps || jsonb_build_array(
             jsonb_build_object('text', v_text, 'confirmed', v_confirm)),
           step_index = step_index + 1,
           stage = 'work', work_text = null, wrong_streak = 0, hint_tier = 0,
           hint_unlocked = false,
           completed = (step_index + 1 >= v_required),
           updated_at = now()
     where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
     returning * into v_st;
    if v_st.completed then v_outcome := 'question_done'; end if;
  end if;

  return jsonb_build_object(
    'outcome',   v_outcome,
    'step_text', v_text,
    'confirmed', v_confirm,
    'state',     public.pia_step_state_json(v_sq, v_st),
    'clock',     public.pia_clock_json(v_w));
end;
$$;


--
-- Name: check_student_session(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_student_session() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email  text := auth.jwt() ->> 'email';
  v_sid    uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_role   text;
  v_active uuid;
begin
  if v_email is null then
    return jsonb_build_object('status', 'none');
  end if;

  select lower(trim(coalesce(p.role, 'student'))), p.active_session_id
    into v_role, v_active
    from public.profiles p
   where p.email = v_email;

  if not found then
    return jsonb_build_object('status', 'none');
  end if;

  if v_role in ('admin', 'teacher') then
    return jsonb_build_object('status', 'active');
  end if;

  -- Checked BEFORE the revocation test on purpose: a takeover also stamps
  -- sessions_revoked_at, and the student should be told the real reason.
  if v_active is not null and v_sid is not null and v_active <> v_sid then
    return jsonb_build_object('status', 'replaced');
  end if;

  if not public.jwt_is_current() then
    return jsonb_build_object('status', 'revoked');
  end if;

  -- Signed in before 0027 existed: adopt this session. "is null" in the
  -- WHERE keeps it first-come -- a second device checking in a moment later
  -- finds the slot taken and is told 'replaced' on its next beat.
  if v_active is null and v_sid is not null then
    update public.profiles
       set active_session_id = v_sid,
           active_session_at = now()
     where email = v_email and active_session_id is null;
  end if;

  return jsonb_build_object('status', 'active');
end;
$$;


--
-- Name: claim_device(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_device(p_device_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $_$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_sid     text := nullif(auth.jwt() ->> 'session_id', '');
  v_role    text;
  v_max     int;
  v_devices text[];
  v_map     jsonb;
  v_dead    text[] := '{}';
  d         text;
  s         text;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  if p_device_id is null or length(trim(p_device_id)) = 0 then
    raise exception 'PIA: a device id is required.' using errcode = '22023';
  end if;

  -- FOR UPDATE: two sign-ins racing on one account are served one after the other.
  select lower(trim(coalesce(p.role, 'student'))), coalesce(p.max_devices, 1),
         coalesce(p.active_devices, '{}'), coalesce(p.device_sessions, '{}'::jsonb)
    into v_role, v_max, v_devices, v_map
    from public.profiles p
   where p.email = v_email
     for update;

  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  -- 0032: forget devices whose recorded login no longer exists.
  foreach d in array v_devices loop
    s := v_map ->> d;
    if s ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       and not exists (select 1 from auth.sessions x where x.id = s::uuid) then
      v_dead := array_append(v_dead, d);
    end if;
  end loop;

  if coalesce(array_length(v_dead, 1), 0) > 0 then
    v_devices := array(select x from unnest(v_devices) x where not (x = any(v_dead)));
    foreach d in array v_dead loop
      v_map := v_map - d;
    end loop;
    update public.profiles
       set active_devices = v_devices, device_sessions = v_map
     where email = v_email;
  end if;

  -- Known device: nothing to add (idempotent), but keep its session current.
  if p_device_id = any(v_devices) then
    if v_sid is not null and (v_map ->> p_device_id) is distinct from v_sid then
      update public.profiles
         set device_sessions = v_map || jsonb_build_object(p_device_id, v_sid)
       where email = v_email;
    end if;
    return jsonb_build_object('allowed', true, 'devices', v_devices, 'max', v_max);
  end if;

  -- 0032: the limit does not apply to administrators.
  if v_role <> 'admin' and coalesce(array_length(v_devices, 1), 0) >= v_max then
    return jsonb_build_object(
      'allowed', false,
      'reason', v_max || ' device limit reached. Please sign out on your other device first.',
      'devices', v_devices, 'max', v_max);
  end if;

  update public.profiles
     set active_devices  = array_append(v_devices, p_device_id),
         device_sessions = case when v_sid is null then v_map
                                else v_map || jsonb_build_object(p_device_id, v_sid) end
   where email = v_email;

  return jsonb_build_object('allowed', true,
                            'devices', array_append(v_devices, p_device_id),
                            'max', v_max);
end;
$_$;


--
-- Name: claim_student_session(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_student_session(p_device_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email  text   := auth.jwt() ->> 'email';
  v_uid    uuid   := nullif(auth.jwt() ->> 'sub', '')::uuid;
  v_sid    uuid   := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_iat    bigint := nullif(auth.jwt() ->> 'iat', '')::bigint;
  v_device text   := trim(coalesce(p_device_id, ''));
  v_role   text;
  v_active uuid;
begin
  if v_email is null or v_uid is null or v_iat is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  -- A token an admin already revoked may not take the account back.
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  if v_device = '' or length(v_device) > 120 then
    raise exception 'PIA: a device id is required.' using errcode = '22023';
  end if;

  -- FOR UPDATE: two sign-ins racing on one account are served one after the
  -- other, so exactly one of them ends up active. The role is read from the
  -- row itself -- the claim must work before anything else on the page does.
  select lower(trim(coalesce(p.role, 'student'))), p.active_session_id
    into v_role, v_active
    from public.profiles p
   where p.email = v_email
     for update;

  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  -- Cannot be tracked without the claim; let the sign-in through.
  if v_sid is null then
    return jsonb_build_object('ok', true, 'enforced', false);
  end if;

  -- Already the active session (a repeated call): nothing to cut off.
  if v_active is not distinct from v_sid then
    return jsonb_build_object('ok', true, 'enforced', true);
  end if;

  update public.profiles
     set active_session_id   = v_sid,
         active_session_at   = now(),
         -- Every token issued before this one is now stale; this one is not.
         sessions_revoked_at = greatest(coalesce(sessions_revoked_at, '-infinity'::timestamptz),
                                        to_timestamp(v_iat)),
         active_devices = array[v_device], device_sessions = jsonb_build_object(v_device, v_sid::text)
   where email = v_email;

  -- The other devices lose their refresh tokens; this session stays.
  delete from auth.sessions
   where user_id = v_uid and id <> v_sid;
  delete from auth.refresh_tokens
   where user_id = v_uid::text and session_id is distinct from v_sid;

  return jsonb_build_object('ok', true, 'enforced', true);
end;
$$;


--
-- Name: consume_hint(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consume_hint(p_session_id uuid, p_problem_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_used  int;
  v_total int;
  v_next  int;
  v_text  text;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  select count(*) into v_total from public.math_hints where problem_id = p_problem_id;
  if v_total = 0 then
    raise exception 'PIA: there are no hints for this problem.' using errcode = '22023';
  end if;

  select count(*) into v_used
    from public.hint_consumptions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  if v_used >= v_total then
    return jsonb_build_object('hint_text', null, 'hints_used', v_used,
                              'hints_left', 0, 'exhausted', true);
  end if;

  v_next := v_used + 1;
  select hint_text into v_text
    from public.math_hints where problem_id = p_problem_id and hint_index = v_next;

  insert into public.hint_consumptions (session_id, student_email, problem_id, hint_index)
  values (p_session_id, v_email, p_problem_id, v_next)
  on conflict do nothing;

  return jsonb_build_object('hint_text', v_text, 'hints_used', v_next,
                            'hints_left', v_total - v_next,
                            'exhausted', v_next >= v_total);
end;
$$;


--
-- Name: consume_question_hint(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consume_question_hint(p_session_id uuid, p_problem_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_sq    public.served_questions%rowtype;
  v_total int;
  v_used  int;
  v_att   int;
  v_ok    boolean;
  l       record;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  if not found then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  select count(*) into v_used from public.hint_consumptions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  select count(*) into v_total from public.pia_question_hint_list(v_sq.steps, v_sq.default_hint);

  select count(*), coalesce(bool_or(was_correct), false) into v_att, v_ok
    from public.question_attempts
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  -- A closed question takes no more hints; its worked solution comes from
  -- reveal_question_solution().
  if v_ok or v_att >= 2 then
    return jsonb_build_object('hint', null, 'hints_used', v_used, 'hints_left', 0,
                              'exhausted', true, 'locked', true);
  end if;

  if v_used >= v_total then
    return jsonb_build_object('hint', null, 'hints_used', v_used, 'hints_left', 0,
                              'exhausted', true, 'locked', false);
  end if;

  select * into l from public.pia_question_hint_list(v_sq.steps, v_sq.default_hint) h
   where h.idx = v_used + 1;

  insert into public.hint_consumptions (session_id, student_email, problem_id, hint_index)
  values (p_session_id, v_email, p_problem_id, v_used + 1)
  on conflict do nothing;

  return jsonb_build_object(
    'hint', jsonb_build_object(
      'index', l.idx, 'step', l.step, 'steps_total', l.steps_total,
      'tier', l.tier, 'tier_label', public.pia_tier_label(l.tier),
      'step_prompt', l.step_prompt, 'text', l.hint),
    'hints_used', v_used + 1,
    'hints_left', v_total - v_used - 1,
    'exhausted',  v_used + 1 >= v_total,
    'locked',     false);
end;
$$;


--
-- Name: consume_step_hint(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consume_step_hint(p_session_id uuid, p_problem_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email text;
  v_sq    public.served_questions%rowtype;
  v_st    public.step_states%rowtype;
  v_list  text[];
  v_tier  int;
  v_w     public.game_windows%rowtype;
begin
  v_email := public.pia_game_email();
  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  select * into v_st from public.step_states
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
   for update;
  if v_sq.problem_id is null or v_st.problem_id is null then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  v_w := public.pia_game_window(p_session_id, v_email);
  if v_st.completed or not v_st.hint_unlocked or public.pia_window_expired(v_w) then
    return jsonb_build_object('hint', null, 'state', public.pia_step_state_json(v_sq, v_st),
                              'clock', public.pia_clock_json(v_w));
  end if;

  v_list := public.pia_step_hints(v_sq.steps -> v_st.step_index, v_sq.default_hint);
  v_tier := least(v_st.hint_tier + 1, cardinality(v_list));

  insert into public.step_hints (session_id, student_email, problem_id, step_index, tier, tiers_total)
  values (p_session_id, v_email, p_problem_id, v_st.step_index, v_tier, cardinality(v_list));

  update public.step_states
     set hint_tier = v_tier, hints = hints + 1, updated_at = now()
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
   returning * into v_st;

  return jsonb_build_object(
    'hint', jsonb_build_object(
      'text', public.pia_mask_answers(v_list[v_tier],
                array[v_sq.steps -> v_st.step_index ->> 'answer', v_sq.final_answer]),
      'tier', v_tier, 'tiers_total', cardinality(v_list),
      'step', v_st.step_index + 1),
    'state', public.pia_step_state_json(v_sq, v_st),
    'clock', public.pia_clock_json(v_w));
end;
$$;


--
-- Name: current_email(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_email() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select nullif(auth.jwt() ->> 'email', '')::text;
$$;


--
-- Name: current_role_name(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_role_name() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select lower(trim(p.role))
  from public.profiles p
  where p.email = public.current_email()
  limit 1;
$$;


--
-- Name: current_user_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_user_role() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    select lower(trim(role)) from public.profiles
    where email = auth.jwt() ->> 'email' limit 1;
$$;


--
-- Name: current_user_section(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_user_section() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    select section from public.profiles
    where email = auth.jwt() ->> 'email' limit 1;
$$;


--
-- Name: end_game_session(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.end_game_session(p_session_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

  update public.game_sessions
     set is_active = false, ended_at = now()
   where id = p_session_id
     and student_email = auth.jwt() ->> 'email';
end; $$;


--
-- Name: enforce_device_limit(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_device_limit(p_device_id text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
    v_user_id uuid;
    v_role text;
    v_max_devices int;
    v_active_devices text[];
    v_profile record;
begin
    v_user_id := auth.uid();
    if v_user_id is null then
        raise exception 'Unauthorized';
    end if;

    select role, max_devices, active_devices into v_profile
    from profiles
    where id = v_user_id;

    v_role := coalesce(v_profile.role, 'student');
    v_max_devices := coalesce(v_profile.max_devices, 1);
    v_active_devices := coalesce(v_profile.active_devices, array[]::text[]);

    -- Kung admin, huwag higpitan ang devices
    if lower(v_role) = 'admin' then
        return json_build_object('success', true);
    end if;

    if not (p_device_id = any(v_active_devices)) then
        if array_length(v_active_devices, 1) >= v_max_devices then
            return json_build_object('success', false, 'message', format('%s device limit lang. Please log out from your other active device.', v_max_devices));
        else
            v_active_devices := array_append(v_active_devices, p_device_id);
            update profiles
            set active_devices = v_active_devices
            where id = v_user_id;
        end if;
    end if;

    return json_build_object('success', true);
end;
$$;


--
-- Name: enforce_profile_write_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_profile_write_scope() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  -- Ang TANGING mga column na kayang baguhin ng estudyante sa SARILING row.
  -- Lahat ng iba (role, email, group_type, is_ocean_done, ocean_*,
  -- current_stage, stage_started_at, pre_test_score, post_test_score,
  -- max_devices, section, full_name) ay protektado by default -- pati na ang
  -- anumang bagong column na idadagdag mo sa hinaharap.
  v_student_writable constant text[] := array[
    'selected_character',
    'is_in_game', 'current_problem', 'current_difficulty',
    'hints_used', 'consecutive_correct',
    'status',
    'last_seen', 'updated_at'
  ];
  v_caller_email text := auth.jwt() ->> 'email';
  v_caller_role  text;
begin
  -- (1) Hindi galing sa browser: SECURITY DEFINER RPC o service_role. Trusted.
  if current_user <> 'authenticated' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  v_caller_role := public.pia_caller_role();

  -- (2) Admin: walang pagbabago sa dating asal.
  if v_caller_role = 'admin' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- (3) Estudyante/teacher na direktang sumusulat mula sa browser.
  if tg_op = 'INSERT' then
    raise exception 'PIA: you are not allowed to create a profile row (role=%).', coalesce(v_caller_role, 'unknown')
      using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    raise exception 'PIA: you are not allowed to delete a profile row (role=%).', coalesce(v_caller_role, 'unknown')
      using errcode = '42501';
  end if;

  -- Sariling row lang, at hindi pwedeng ilipat ang row sa ibang email.
  if v_caller_email is null
     or old.email is distinct from v_caller_email
     or new.email is distinct from old.email then
    raise exception 'PIA: you are not allowed to modify a profile that is not yours.'
      using errcode = '42501';
  end if;

  -- Ihambing ang lahat ng column MALIBAN sa whitelist. Kung may naiba doon,
  -- may sinusubukang i-forge -- ibagsak ang buong statement.
  if (to_jsonb(old) - v_student_writable) is distinct from (to_jsonb(new) - v_student_writable) then
    raise exception
      'PIA: direct writes to protected profile columns are not allowed. Use submit_ocean_results() / set_student_stage().'
      using errcode = '42501';
  end if;

  return new;
end;
$$;


--
-- Name: finalize_stage_time(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_stage_time(p_stage text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  v_row     public.student_stage_time%rowtype;
  v_done    boolean;
  v_gap     numeric;
  v_credit  integer := 0;
  v_locked  timestamptz;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  if public.pia_caller_role() is distinct from 'student' then
    return jsonb_build_object('locked', false, 'reason', 'not_a_student');
  end if;

  if p_stage is null or p_stage not in ('OCEAN', 'Character Selection', 'Tutoring Dashboard') then
    return jsonb_build_object('locked', false, 'reason', 'unknown_stage');
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    return jsonb_build_object('locked', false, 'reason', 'no_profile');
  end if;

  v_done := case p_stage
              when 'OCEAN' then coalesce(v_profile.is_ocean_done, false)
              when 'Character Selection' then v_profile.selected_character is not null
              else not coalesce(v_profile.is_in_game, false) end;
  if not v_done then
    return jsonb_build_object('locked', false, 'reason', 'stage_not_completed');
  end if;

  insert into public.student_stage_time (student_email) values (v_profile.email)
  on conflict (student_email) do nothing;

  select * into v_row from public.student_stage_time
   where student_email = v_profile.email for update;

  v_locked := case p_stage when 'OCEAN' then v_row.ocean_time_locked_at
                           when 'Character Selection' then v_row.character_select_time_locked_at
                           else v_row.tutoring_time_locked_at end;
  if v_locked is null then
    if v_row.last_heartbeat_timestamp is not null and v_row.heartbeat_stage = p_stage then
      v_gap := extract(epoch from (now() - v_row.last_heartbeat_timestamp));
      if v_gap >= 10 and v_gap <= 45 then v_credit := least(30, floor(v_gap))::integer; end if;
    end if;

    update public.student_stage_time set
      ocean_time            = ocean_time + case when p_stage = 'OCEAN' then v_credit else 0 end,
      character_select_time = character_select_time + case when p_stage = 'Character Selection' then v_credit else 0 end,
      tutoring_time         = tutoring_time + case when p_stage = 'Tutoring Dashboard' then v_credit else 0 end,
      ocean_time_locked_at  = case when p_stage = 'OCEAN' then now() else ocean_time_locked_at end,
      character_select_time_locked_at = case when p_stage = 'Character Selection' then now() else character_select_time_locked_at end,
      tutoring_time_locked_at = case when p_stage = 'Tutoring Dashboard' then now() else tutoring_time_locked_at end,
      last_heartbeat_timestamp = now()
     where student_email = v_profile.email
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'locked', true,
    'seconds', case p_stage when 'OCEAN' then v_row.ocean_time
                            when 'Character Selection' then v_row.character_select_time
                            else v_row.tutoring_time end);
end;
$$;


--
-- Name: finish_step_question(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finish_step_question(p_session_id uuid, p_problem_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email  text;
  v_sq     public.served_questions%rowtype;
  v_st     public.step_states%rowtype;
  v_prog   public.student_topic_progress%rowtype;
  v_served timestamptz;
  v_last   timestamptz;
  v_ms     bigint;
  v_att    int;
  v_class  text;
  v_acc    boolean;
  v_topic  int;
  v_done   int;
  v_good   int;
  v_streak int;
  v_rule   record;
  v_offer  text;
  v_target int;
  v_pend   public.topic_offers%rowtype;
  v_repeat_prior int;
  v_hints_taken  int;
begin
  v_email := public.pia_game_email();
  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  select * into v_st from public.step_states
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  if v_sq.problem_id is null or v_st.problem_id is null then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  if exists (select 1 from public.tutoring_attempts
              where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id) then
    select * into v_pend from public.topic_offers
     where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id and status = 'pending';
    return public.pia_result_payload(p_session_id, v_email, p_problem_id)
           || jsonb_build_object('errors', v_st.errors,
                'offer', case when v_pend.problem_id is not null then jsonb_build_object(
                  'type', v_pend.offer, 'from_topic', v_pend.from_topic, 'target_topic', v_pend.target_topic) end);
  end if;

  if not v_st.completed then
    raise exception 'PIA: finish every step first.' using errcode = '42501';
  end if;

  select served_at into v_served from public.problem_serves
   where session_id = p_session_id and problem_id = p_problem_id;
  if v_served is null then
    raise exception 'PIA: this question was not served.' using errcode = '42501';
  end if;
  select max(happened_at), count(*) into v_last, v_att from public.step_events
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  v_ms := greatest(0, least(3600000,
            (extract(epoch from (coalesce(v_last, now()) - v_served)) * 1000)::bigint));

  v_acc   := v_st.errors = 0;
  -- The attached game's one rule: accurate = no wrong answer. Hints and
  -- time are recorded (hints_used, time_taken_ms) but do not decide it.
  v_class := case when v_acc then 'smooth' else 'struggling' end;

  -- The topic window.
  insert into public.student_topic_progress (student_email) values (v_email)
  on conflict (student_email) do nothing;
  select * into v_prog from public.student_topic_progress where student_email = v_email for update;

  v_topic := v_prog.topic;
  v_done  := v_prog.stint_answered + 1;
  v_good  := v_prog.stint_correct + case when v_acc then 1 else 0 end;
  v_streak := case when v_acc then 0 else v_prog.failed_streak + 1 end;

  select * into v_rule from public.pia_topic_rules(v_topic);

  v_offer := null;
  if v_topic > 1 and v_streak >= v_rule.max_err then
    v_offer := 'down'; v_target := v_topic - 1;
  elsif v_topic < 3 and v_done >= v_rule.min_q and v_good * 100 >= v_rule.mastery * v_done then
    v_offer := 'up';   v_target := v_topic + 1;
  end if;

  update public.student_topic_progress
     set stint_answered = v_done, stint_correct = v_good, failed_streak = v_streak, updated_at = now()
   where student_email = v_email;

  -- PASSED stays the game's rule (errors < the topic's max errors). The SCORE is no longer a fixed
  -- 100/50: it comes from this question's base points and the admin's scoring rules (pia_compute_score),
  -- saved once, here, by the server. A repeat of a question already completed in this session
  -- scores per the repeat rule. The hint count is the distinct hints actually taken (step, tier).
  select count(*) into v_repeat_prior
    from public.tutoring_attempts t
    join public.served_questions s
      on s.session_id = t.session_id and s.student_email = t.student_email and s.problem_id = t.problem_id
   where t.session_id = p_session_id and t.student_email = v_email and s.question_id = v_sq.question_id;
  select count(*) into v_hints_taken
    from (select distinct step_index, tier from public.step_hints
           where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id) h;

  update public.step_states
     set passed = (v_st.errors < v_rule.max_err),
         score  = coalesce(score, public.pia_compute_score(
                    coalesce(v_sq.base_points, 10), v_st.errors, v_hints_taken, v_ms, v_repeat_prior))
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  if v_offer is not null then
    insert into public.topic_offers (session_id, student_email, problem_id, offer, from_topic, target_topic)
    values (p_session_id, v_email, p_problem_id, v_offer, v_topic, v_target)
    on conflict do nothing;
  end if;

  -- level_before / level_after hold the TOPIC (1-3), as in 0029. A topic
  -- changes only when the student accepts an offer, so they match here.
  insert into public.tutoring_attempts (
    session_id, student_email, problem_id, problem_number,
    level_before, level_after, attempts_used, hints_used,
    time_taken_ms, is_correct, classification)
  values (
    p_session_id, v_email, p_problem_id, v_sq.problem_number,
    v_topic, v_topic, least(10, v_att), least(10, v_st.hints),
    v_ms, v_acc, v_class)
  on conflict (session_id, problem_number) do nothing;

  return public.pia_result_payload(p_session_id, v_email, p_problem_id)
         || jsonb_build_object('errors', v_st.errors,
              'offer', case when v_offer is not null then jsonb_build_object(
                'type', v_offer, 'from_topic', v_topic, 'target_topic', v_target) end);
end;
$$;


--
-- Name: get_learning_features(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_learning_features(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email text := public.pia_game_email();
begin
  if p_session_id is null then
    raise exception 'PIA: a session is required.' using errcode = '22023';
  end if;
  return public.pia_learning_features_calc(p_session_id, v_email);
end;
$$;


--
-- Name: get_session_history(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_session_history(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email text := public.pia_game_email();
begin
  if p_session_id is null then
    raise exception 'PIA: a session is required.' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'solved', coalesce((
      select jsonb_agg(jsonb_build_object(
               'number',   sq.problem_number,
               'topic',    sq.topic,
               'question', sq.question,
               'steps',    (select coalesce(jsonb_agg(jsonb_build_object(
                                'title',     'Step ' || n.i || ': ' || public.pia_step_label(sq.topic, n.i - 1),
                                'text',      d.elem ->> 'text',
                                'confirmed', d.elem ->> 'confirmed') order by n.i), '[]'::jsonb)
                              from jsonb_array_elements(st.done_steps) with ordinality as d(elem, i)
                              cross join lateral (select d.i::int as i) n)) order by sq.problem_number)
        from public.served_questions sq
        join public.step_states st
          on st.session_id = sq.session_id and st.student_email = sq.student_email and st.problem_id = sq.problem_id
       where sq.session_id = p_session_id and sq.student_email = v_email and st.completed
    ), '[]'::jsonb),
    'errors', coalesce((
      select jsonb_agg(e.line order by e.id)
        from (select ev.id,
                     'Step ' || (ev.step_index + 1) || ': '
                       || case when ev.outcome = 'format_error' then 'Final-answer error on "' else 'Error on "' end
                       || ev.submitted || '"' as line
                from public.step_events ev
               where ev.session_id = p_session_id and ev.student_email = v_email
                 and ev.outcome in ('wrong', 'format_error')
               order by ev.id desc limit 5) e
    ), '[]'::jsonb),
    'hints_total', (select count(*)::int from public.step_hints h
                     where h.session_id = p_session_id and h.student_email = v_email));
end;
$$;


--
-- Name: guard_session_start(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_session_start() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_email text := auth.jwt() ->> 'email'; v_n int;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

    if v_email is null then raise exception 'Not authenticated.'; end if;
    select count(*) into v_n from public.session_start_log where student_email = v_email and started_at > now() - interval '1 hour';
    if v_n >= 8 then raise exception 'Too many sessions started. Please wait a moment.' using errcode = 'P0001'; end if;
    insert into public.session_start_log (student_email) values (v_email);
end;
$$;


--
-- Name: handle_new_student_auth(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_student_auth() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  new_user_id uuid;
  default_pass text := 'PIA2026!'; -- Default password ng system
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE email = NEW.email) THEN
    new_user_id := gen_random_uuid();
    
    -- Insert sa auth.users
    INSERT INTO auth.users (
      id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) VALUES (
      new_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', NEW.email, crypt(default_pass, gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()
    );
    
    -- Insert sa auth.identities para mapayagan ang login
    INSERT INTO auth.identities (
      provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at, id
    ) VALUES (
      new_user_id::text, new_user_id, format('{"sub":"%s","email":"%s"}', new_user_id::text, NEW.email)::jsonb, 'email', now(), now(), now(), gen_random_uuid()
    );
    
    -- I-sync ang ID
    UPDATE public.profiles SET id = new_user_id WHERE email = NEW.email;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: is_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select coalesce(public.current_role_name() = 'admin', false);
$$;


--
-- Name: is_teacher(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_teacher() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select coalesce(public.current_role_name() = 'teacher', false);
$$;


--
-- Name: jwt_is_current(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.jwt_is_current() RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_revoked timestamptz;
  v_iat     bigint;
  v_sid     uuid;
begin
  v_iat := nullif(auth.jwt() ->> 'iat', '')::bigint;
  if v_iat is null then return false; end if;

  select sessions_revoked_at into v_revoked from public.profiles where email = auth.jwt() ->> 'email';
  if v_revoked is not null and to_timestamp(v_iat) < v_revoked then return false; end if;

  begin
    v_sid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  exception when invalid_text_representation then
    v_sid := null;
  end;

  -- The session was deleted (a device revoked, "Sign out everywhere", an
  -- account removed): this token is finished, whatever its expiry says.
  if v_sid is not null and not exists (select 1 from auth.sessions s where s.id = v_sid) then
    return false;
  end if;

  return true;
end;
$$;


--
-- Name: pia_admin_boundaries(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_admin_boundaries() RETURNS trigger
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
    if v_old_adm then
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


--
-- Name: pia_admin_tutorial_report(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_admin_tutorial_report(p_student_email text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email text := lower(trim(coalesce(p_student_email, '')));
  v_report jsonb;
begin
  if coalesce(public.pia_caller_role(), '') <> 'admin'
     or public.jwt_is_current() is not true then
    raise exception 'PIA: admin access required.' using errcode = '42501';
  end if;
  if v_email = '' then
    raise exception 'PIA: student email required.' using errcode = '22023';
  end if;

  with windows as (
    select w.session_id, w.student_email, w.window_no, w.started_at,
           w.deadline_at, w.ended_at,
           greatest(0, floor(extract(epoch from
             least(coalesce(w.ended_at, now()), w.deadline_at) - w.started_at)))::int
             as duration_seconds
      from public.game_windows w
     where lower(w.student_email) = v_email
  ), report_rows as (
    select w.*,
           coalesce(a.completed, 0) as completed,
           coalesce(a.clean, 0) as clean,
           a.best_topic,
           coalesce(a.time_sum_ms, 0) as time_sum_ms,
           coalesce(a.timed_count, 0) as timed_count,
           coalesce(a.score_sum, 0) as score_sum,
           coalesce(e.errors, 0) as errors,
           coalesce(h.hints, 0) as hints
      from windows w
      left join lateral (
        select count(*)::int as completed,
               count(*) filter (where t.is_correct)::int as clean,
               max(t.level_before) as best_topic,
               sum(t.time_taken_ms) as time_sum_ms,
               count(t.time_taken_ms)::int as timed_count,
               sum(coalesce(st.score, 0))::int as score_sum
          from public.tutoring_attempts t
          join lateral (
            select max(ev.happened_at) as done_at
              from public.step_events ev
             where ev.session_id = t.session_id and ev.student_email = t.student_email
               and ev.problem_id = t.problem_id and ev.outcome = 'question_done'
          ) c on c.done_at is not null
          left join public.step_states st
            on st.session_id = t.session_id and st.student_email = t.student_email
           and st.problem_id = t.problem_id
         where t.session_id = w.session_id and t.student_email = w.student_email
           and t.problem_id like 'qb-%'
           and c.done_at >= w.started_at and c.done_at < w.deadline_at
      ) a on true
      left join lateral (
        select count(*)::int as errors
          from public.step_events ev
         where ev.session_id = w.session_id and ev.student_email = w.student_email
           and ev.outcome in ('wrong', 'format_error')
           and ev.happened_at >= w.started_at and ev.happened_at < w.deadline_at
      ) e on true
      left join lateral (
        select count(*)::int as hints
          from public.step_hints sh
         where sh.session_id = w.session_id and sh.student_email = w.student_email
           and sh.taken_at >= w.started_at and sh.taken_at < w.deadline_at
      ) h on true
  )
  select jsonb_build_object(
    'summary', jsonb_build_object(
      'sessions', count(*)::int,
      'completed_questions', coalesce(sum(completed), 0)::int,
      'clean_questions', coalesce(sum(clean), 0)::int,
      'best_topic', max(best_topic),
      'avg_speed_seconds', case when coalesce(sum(timed_count), 0) > 0
        then round(sum(time_sum_ms)::numeric / sum(timed_count) / 1000, 1)
        else null end,
      'accuracy_percent', case when coalesce(sum(completed), 0) > 0
        then round(sum(clean)::numeric * 100 / sum(completed), 1)
        else null end,
      'score_sum', coalesce(sum(score_sum), 0)::int,
      'errors', coalesce(sum(errors), 0)::int,
      'hints', coalesce(sum(hints), 0)::int
    ),
    'history_total', count(*)::int,
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'started_at', r.started_at,
        'window_no', r.window_no,
        'status', case when r.ended_at is not null or r.deadline_at <= now()
          then 'ended' else 'active' end,
        'duration_seconds', r.duration_seconds,
        'best_topic', r.best_topic,
        'completed_questions', r.completed,
        'clean_questions', r.clean,
        'score_sum', r.score_sum,
        'errors', r.errors,
        'hints', r.hints
      ) order by r.started_at desc, r.window_no desc)
        from (select * from report_rows order by started_at desc, window_no desc limit 100) r
    ), '[]'::jsonb)
  ) into v_report
    from report_rows;

  return v_report;
end;
$$;


--
-- Name: pia_answer_matches(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_answer_matches(p_submitted text, p_key text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $$
declare
  s      text := replace(lower(coalesce(p_submitted, '')), ',', '');
  k      text := replace(lower(coalesce(p_key, '')), ',', '');
  s_nums text[];
  k_nums text[];
  s_text text;
begin
  select array_agg(m[1]) into s_nums from regexp_matches(s, '(-?[0-9]*\.?[0-9]+)', 'g') as m;
  select array_agg(m[1]) into k_nums from regexp_matches(k, '(-?[0-9]*\.?[0-9]+)', 'g') as m;

  if coalesce(array_length(k_nums, 1), 0) = 1 then
    return coalesce(array_length(s_nums, 1), 0) = 1
       and abs(s_nums[1]::numeric - k_nums[1]::numeric) < 0.000001;
  end if;

  s_text := regexp_replace(s, '[^a-z0-9%.-]', '', 'g');
  return s_text <> '' and s_text = regexp_replace(k, '[^a-z0-9%.-]', '', 'g');
end;
$$;


--
-- Name: pia_assign_tutor_from_ocean(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_assign_tutor_from_ocean() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  -- Only a newly completed questionnaire for an Assigned student counts.
  -- The retake action resets is_ocean_done, so it also gets a new assignment.
  -- Existing manual choices are intentionally replaced by this result.
  if new.source = 'questionnaire' then
    update public.profiles p
       set selected_character = public.pia_choose_assigned_character(
         new.ocean_e, new.ocean_a, new.ocean_c, new.ocean_n, new.ocean_o)
     where p.email = new.email
       and lower(trim(coalesce(p.group_type, ''))) = 'assigned'
       and not coalesce(p.is_ocean_done, false);
  end if;
  return new;
end;
$$;


--
-- Name: pia_audit_profiles(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_audit_profiles() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_actor  text := lower(nullif(auth.jwt() ->> 'email', ''));
  v_arole  text;
  v_old    jsonb;
  v_new    jsonb;
  v_target text;
  v_owner  boolean;
  v_admin  boolean;
  v_gone   jsonb;
begin
  if v_actor is not null then v_arole := public.pia_caller_role(); end if;

  if tg_op = 'INSERT' then
    if lower(trim(coalesce(new.role, ''))) in ('admin', 'teacher') then
      insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
      values (v_actor, v_arole, 'account.created', new.email,
              jsonb_build_object('role', lower(trim(new.role))));
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
    values (v_actor, v_arole, 'account.deleted', old.email,
            jsonb_build_object('role', lower(trim(coalesce(old.role, 'student')))));
    return old;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  v_target := new.email;
  v_owner := v_actor is not null and lower(old.email) = v_actor;
  v_admin := lower(trim(coalesce(old.role, ''))) = 'admin';

  if (v_old ->> 'role') is distinct from (v_new ->> 'role') then
    insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
    values (v_actor, v_arole, 'role.changed', v_target,
            jsonb_build_object('from', v_old ->> 'role', 'to', v_new ->> 'role'));
  end if;

  if (v_old -> 'max_devices') is distinct from (v_new -> 'max_devices') then
    insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
    values (v_actor, v_arole, 'device_limit.changed', v_target,
            jsonb_build_object('from', v_old -> 'max_devices', 'to', v_new -> 'max_devices'));
  end if;

  if (v_old ->> 'email') is distinct from (v_new ->> 'email') then
    insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
    values (v_actor, v_arole, 'email.changed', v_target,
            jsonb_build_object('from', v_old ->> 'email', 'to', v_new ->> 'email'));
  end if;

  -- Ordinary sign-ins and sign-outs change these on every student's own row;
  -- only an administrator's row, or someone else acting on the row, is logged.
  if v_admin or not v_owner then
    select coalesce(jsonb_agg(d), '[]'::jsonb) into v_gone
      from jsonb_array_elements_text(coalesce(v_old -> 'active_devices', '[]'::jsonb)) d
     where not (coalesce(v_new -> 'active_devices', '[]'::jsonb) ? d);
    if jsonb_array_length(v_gone) > 0 then
      insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
      values (v_actor, v_arole, 'devices.removed', v_target, jsonb_build_object('devices', v_gone));
    end if;

    if (v_old -> 'sessions_revoked_at') is distinct from (v_new -> 'sessions_revoked_at') then
      insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
      values (v_actor, v_arole, 'sessions.revoked', v_target, '{}'::jsonb);
    end if;
  end if;

  return new;
end;
$$;


--
-- Name: pia_auth_user_id(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_auth_user_id(p_email text) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $$
  select u.id
    from auth.users u
   where lower(u.email) = lower(trim(p_email))
   limit 1;
$$;


--
-- Name: pia_bfpt_score(integer[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_bfpt_score(r integer[]) RETURNS TABLE(ocean_e integer, ocean_a integer, ocean_c integer, ocean_n integer, ocean_o integer)
    LANGUAGE sql IMMUTABLE STRICT
    SET search_path TO 'public'
    AS $$
  select
    -- E = 20 + (1) - (6) + (11) - (16) + (21) - (26) + (31) - (36) + (41) - (46)
    20 + r[1]  - r[6]  + r[11] - r[16] + r[21] - r[26] + r[31] - r[36] + r[41] - r[46],
    -- A = 14 - (2) + (7) - (12) + (17) - (22) + (27) - (32) + (37) + (42) + (47)
    14 - r[2]  + r[7]  - r[12] + r[17] - r[22] + r[27] - r[32] + r[37] + r[42] + r[47],
    -- C = 14 + (3) - (8) + (13) - (18) + (23) - (28) + (33) - (38) + (43) + (48)
    14 + r[3]  - r[8]  + r[13] - r[18] + r[23] - r[28] + r[33] - r[38] + r[43] + r[48],
    -- N = 38 - (4) + (9) - (14) + (19) - (24) - (29) - (34) - (39) - (44) - (49)
    38 - r[4]  + r[9]  - r[14] + r[19] - r[24] - r[29] - r[34] - r[39] - r[44] - r[49],
    -- O = 8 + (5) - (10) + (15) - (20) + (25) - (30) + (35) + (40) + (45) + (50)
     8 + r[5]  - r[10] + r[15] - r[20] + r[25] - r[30] + r[35] + r[40] + r[45] + r[50]
$$;


--
-- Name: pia_caller_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_caller_role() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  -- The caller's role, RLS-bypassing so the profiles policies do not recurse
  -- -- and NULL once their session has been revoked (0022), so every admin,
  -- teacher and student check built on this refuses a stale token.
  select case when public.jwt_is_current() then
    (select lower(trim(coalesce(p.role, 'student')))
       from public.profiles p
      where p.email = (auth.jwt() ->> 'email')
      limit 1)
  end;
$$;


--
-- Name: pia_can_enter_stage(boolean, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_can_enter_stage(p_is_ocean_done boolean, p_group_type text, p_selected_character text, p_stage text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  select case p_stage
    when 'OCEAN' then
      not coalesce(p_is_ocean_done, false)
    when 'Character Selection' then
      coalesce(p_is_ocean_done, false)
      and lower(trim(coalesce(p_group_type, ''))) in ('non-assigned', 'non_assigned')
      and p_selected_character is null
    when 'Tutoring Dashboard' then
      coalesce(p_is_ocean_done, false)
      and lower(trim(coalesce(p_group_type, ''))) <> 'control'
      and not (lower(trim(coalesce(p_group_type, ''))) in ('non-assigned', 'non_assigned')
               and p_selected_character is null)
    when 'Waiting Room' then
      true
    else false
  end;
$$;


--
-- Name: pia_choose_assigned_character(integer, integer, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_choose_assigned_character(p_e integer, p_a integer, p_c integer, p_n integer, p_o integer) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_choice text;
begin
  if num_nonnulls(p_e, p_a, p_c, p_n, p_o) <> 5
     or p_e not between 0 and 40 or p_a not between 0 and 40
     or p_c not between 0 and 40 or p_n not between 0 and 40
     or p_o not between 0 and 40 then
    raise exception 'PIA: invalid questionnaire scores.' using errcode = '22023';
  end if;

  -- The BFPT sheet's N formula runs opposite to its prose definition: a low
  -- stored N means more stress. Reverse N for character matching only. The
  -- existing pia-calm key points to the Neuroticism character in the artwork.
  select candidate.character_key into v_choice
    from (values
      ('pia-extravert',     p_e),
      ('pia-agreeable',     p_a),
      ('pia-conscientious', p_c),
      ('pia-calm',          40 - p_n),
      ('pia-open',          p_o)
    ) as candidate(character_key, score)
   where candidate.score = greatest(p_e, p_a, p_c, 40 - p_n, p_o)
   order by random()
   limit 1;

  return v_choice;
end;
$$;


--
-- Name: pia_clear_stage_overrides(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_clear_stage_overrides() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.key like 'stage\_%' then
    delete from public.stage_overrides where stage = substr(new.key, 7);
  end if;
  return null;
end;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: game_windows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.game_windows (
    session_id uuid NOT NULL,
    student_email text NOT NULL,
    window_no integer NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    limit_seconds integer NOT NULL,
    deadline_at timestamp with time zone NOT NULL,
    ended_at timestamp with time zone,
    ended_reason text,
    topic integer,
    open_problem_id text,
    errors integer,
    hints integer
);


--
-- Name: pia_clock_json(public.game_windows); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_clock_json(w public.game_windows) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  select jsonb_build_object(
    'window',            w.window_no,
    'closed',            public.pia_tutoring_closed_for(w.student_email),
    'expired',           public.pia_tutoring_closed_for(w.student_email),
    'limit_seconds',     86400,
    'remaining_seconds', 86400);
$$;


--
-- Name: pia_close_idle_game_sessions(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_close_idle_game_sessions(p_dry_run boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_windows  int := 0;
  v_profiles int := 0;
begin
  if p_dry_run then
    select count(*) into v_windows from public.pia_idle_game_windows();
    select count(*) into v_profiles
      from public.profiles p
     where lower(trim(coalesce(p.role, 'student'))) = 'student'
       and (p.is_in_game or coalesce(array_length(p.active_devices, 1), 0) > 0)
       and not exists (select 1 from public.student_presence sp
                        where lower(sp.student_email) = lower(p.email)
                          and sp.last_seen > now() - interval '20 minutes');
    return jsonb_build_object('dry_run', true, 'windows_would_close', v_windows, 'profiles_would_clear', v_profiles);
  end if;

  update public.game_windows w
     set ended_at     = i.last_activity,
         ended_reason = case when i.last_activity - i.started_at > interval '6 hours' then 'idle-long' else 'idle' end
    from public.pia_idle_game_windows() i
   where w.session_id = i.session_id
     and w.student_email = i.student_email
     and w.window_no = i.window_no
     and w.ended_at is null;
  get diagnostics v_windows = row_count;

  update public.profiles p
     set is_in_game = false,
         active_devices = '{}'
   where lower(trim(coalesce(p.role, 'student'))) = 'student'
     and (p.is_in_game or coalesce(array_length(p.active_devices, 1), 0) > 0)
     and not exists (select 1 from public.student_presence sp
                      where lower(sp.student_email) = lower(p.email)
                        and sp.last_seen > now() - interval '20 minutes');
  get diagnostics v_profiles = row_count;

  return jsonb_build_object('dry_run', false, 'windows_closed', v_windows, 'profiles_cleared', v_profiles);
end;
$$;


--
-- Name: pia_compute_score(integer, integer, integer, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_compute_score(p_base integer, p_errors integer, p_hints integer, p_ms bigint, p_repeat_prior integer) RETURNS integer
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  c        public.app_config%rowtype;
  v_base   numeric := greatest(0, coalesce(p_base, 0));
  v_raw    numeric;
  v_score  numeric;
begin
  select * into c from public.app_config where id = 1;
  if not found then
    c.score_wrong_pct := 20; c.score_hint_pct := 10; c.score_fast_bonus_pct := 20; c.score_fast_seconds := 30;
    c.score_speed_bonus := true; c.score_min := 0; c.score_repeat_enabled := false; c.score_repeat_pct := 50;
  end if;

  v_raw := v_base
         - v_base * c.score_wrong_pct / 100.0 * greatest(0, coalesce(p_errors, 0))
         - v_base * c.score_hint_pct  / 100.0 * greatest(0, coalesce(p_hints, 0));
  -- Speed only ever ADDS, and only to a question with no wrong answer. Slow answers lose nothing.
  if c.score_speed_bonus and coalesce(p_errors, 0) = 0 and p_ms is not null and p_ms >= 0
     and p_ms <= c.score_fast_seconds * 1000::bigint then
    v_raw := v_raw + v_base * c.score_fast_bonus_pct / 100.0;
  end if;
  v_score := greatest(c.score_min, round(v_raw));

  if coalesce(p_repeat_prior, 0) > 0 then
    v_score := case when c.score_repeat_enabled then greatest(0, round(v_score * c.score_repeat_pct / 100.0)) else 0 end;
  end if;
  return v_score::int;
end;
$$;


--
-- Name: pia_compute_test_scores(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_compute_test_scores() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_insert boolean := tg_op = 'INSERT';
begin
  new.pre_test_score := public.pia_settle_test_score('pre-test', v_insert,
    new.pre_test_raw_score, new.pre_test_max_score, new.pre_test_score,
    case when v_insert then null else old.pre_test_raw_score end,
    case when v_insert then null else old.pre_test_max_score end,
    case when v_insert then null else old.pre_test_score end);

  new.post_test_score := public.pia_settle_test_score('post-test', v_insert,
    new.post_test_raw_score, new.post_test_max_score, new.post_test_score,
    case when v_insert then null else old.post_test_raw_score end,
    case when v_insert then null else old.post_test_max_score end,
    case when v_insert then null else old.post_test_score end);

  return new;
end;
$$;


--
-- Name: pia_control_stage_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_control_stage_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if lower(trim(coalesce(new.group_type, ''))) = 'control'
     and new.current_stage in ('Character Selection', 'Tutoring Dashboard')
     and (tg_op = 'INSERT' or new.current_stage is distinct from old.current_stage) then
    if tg_op = 'INSERT' then
      new.current_stage := 'Waiting Room';
    else
      -- Keep the student where they are. A Control student already in the
      -- dashboard before this migration is not moved by it either.
      new.current_stage    := old.current_stage;
      new.stage_started_at := old.stage_started_at;
      new.is_in_game       := old.is_in_game;
    end if;
  end if;

  -- "In a tutoring session" is written by the student's own browser
  -- (is_in_game is student-writable). A Control student has no session, so a
  -- write that would start one is dropped. A row that already says true is
  -- left as it is (not cleared by this migration).
  if lower(trim(coalesce(new.group_type, ''))) = 'control'
     and coalesce(new.is_in_game, false)
     and (tg_op = 'INSERT' or not coalesce(old.is_in_game, false)) then
    new.is_in_game := false;
  end if;
  return new;
end;
$$;


--
-- Name: pia_eval_expr(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_eval_expr(p_text text) RETURNS numeric
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $_$
declare
  e text := coalesce(p_text, '');
  r numeric;
begin
  e := replace(e, ',', '');
  e := regexp_replace(e, 'PHP|₱', '', 'gi');
  e := translate(e, '×·÷−', '**/-');
  e := replace(e, '%', '');
  e := regexp_replace(e, '(\d|\))\s*[xX]\s*(\d|\()', '\1*\2', 'g');
  e := btrim(e);

  if e = '' or length(e) > 60 then return null; end if;
  if e !~ '^[0-9+*/(). [:space:]-]+$' then return null; end if;
  if position('--' in e) > 0 or position('/*' in e) > 0 or position('*/' in e) > 0 then
    return null;
  end if;

  -- Every number becomes numeric first, or 80/100 would be integer division.
  e := regexp_replace(e, '(\d+\.?\d*|\.\d+)', '(\1)::numeric', 'g');

  begin
    execute 'select (' || e || ')::numeric' into r;
  exception when others then
    return null;       -- syntax error, divide by zero, overflow
  end;
  return r;
end;
$_$;


--
-- Name: pia_forget_deleted_student(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_forget_deleted_student() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  delete from public.student_numbers   where lower(email) = lower(old.email);
  delete from public.join_requests     where lower(email) = lower(old.email);
  delete from public.attendance_marks  where lower(email) = lower(old.email);
  return old;
end;
$$;


--
-- Name: pia_format_final(text, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_format_final(p_kind text, p_value numeric) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  select trim_scale(round(p_value, 10))::text || case when p_kind = 'percentage' then '%' else '' end;
$$;


--
-- Name: pia_game_email(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_game_email() RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email text := auth.jwt() ->> 'email';
  p       public.profiles%rowtype;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'student' then
    raise exception 'PIA: only students take lessons.' using errcode = '42501';
  end if;

  select * into p from public.profiles where email = v_email;
  if not found
     or not public.pia_can_enter_stage(p.is_ocean_done, p.group_type, p.selected_character, 'Tutoring Dashboard')
     or lower(trim(coalesce(p.group_type, ''))) not in ('assigned', 'neutral', 'non-assigned', 'non_assigned')
     or p.selected_character is null then
    raise exception 'PIA: the tutoring game is not available to this account.' using errcode = '42501';
  end if;
  return v_email;
end;
$$;


--
-- Name: pia_game_window(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_game_window(p_session_id uuid, p_email text) RETURNS public.game_windows
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  w        public.game_windows%rowtype;
  v_closes timestamptz;
  v_closed boolean;
begin
  select t.closes_at into v_closes
    from public.profiles p
    join public.tutoring_schedule t on t.section = nullif(trim(p.section), '')
   where lower(p.email) = lower(p_email) limit 1;
  v_closed := public.pia_tutoring_closed_for(p_email);

  select * into w from public.game_windows
   where session_id = p_session_id and student_email = p_email
   order by window_no desc limit 1;

  if found then
    if w.ended_at is null and v_closed then
      update public.game_windows
         set ended_at = greatest(coalesce(v_closes, now()), w.started_at), ended_reason = 'closed'
       where session_id = w.session_id and student_email = w.student_email and window_no = w.window_no
       returning * into w;
      return w;
    end if;
    if w.ended_at is not null and not v_closed then
      insert into public.game_windows (session_id, student_email, window_no, limit_seconds, deadline_at)
      values (p_session_id, p_email, w.window_no + 1, 0, 'infinity')
      returning * into w;
    end if;
    return w;
  end if;

  insert into public.game_windows (session_id, student_email, window_no, limit_seconds, deadline_at)
  values (p_session_id, p_email, 1, 0, 'infinity')
  returning * into w;
  return w;
end;
$$;


--
-- Name: pia_guard_tutor_choice(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_guard_tutor_choice() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if current_user <> 'authenticated' then return new; end if;
  if new.selected_character is not distinct from old.selected_character then return new; end if;
  if public.pia_caller_role() = 'admin' then return new; end if;

  if old.selected_character is null
     and lower(trim(coalesce(old.group_type, ''))) in ('non-assigned', 'non_assigned')
     and new.selected_character in ('pia-open', 'pia-conscientious', 'pia-extravert',
                                    'pia-agreeable', 'pia-calm', 'pia-neutral') then
    return new;
  end if;

  raise exception 'PIA: your tutor is set for you and cannot be changed here.' using errcode = '42501';
end;
$$;


--
-- Name: pia_has_working(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_has_working(p_text text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  with t as (
    select regexp_replace(translate(btrim(coalesce(p_text, '')), '×·÷−', '**/-'), '^[+-]\s*', '') as w
  )
  select w ~ '[*/^()]'
      or w ~ '\d\s*[xX]\s*(\d|\.)'
      or w ~ '(\d|\))\s*[+-]\s*(\d|\()'
  from t;
$$;


--
-- Name: pia_idle_game_windows(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_idle_game_windows() RETURNS TABLE(session_id uuid, student_email text, window_no integer, started_at timestamp with time zone, last_activity timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select w.session_id, w.student_email, w.window_no, w.started_at,
         greatest(w.started_at, coalesce(a.last_activity, w.started_at)) as last_activity
    from public.game_windows w
    left join lateral (
      select max(t) as last_activity
        from (
          select max(e.happened_at) as t from public.step_events e
           where e.session_id = w.session_id and e.student_email = w.student_email and e.happened_at >= w.started_at
          union all
          select max(h.taken_at) from public.step_hints h
           where h.session_id = w.session_id and h.student_email = w.student_email and h.taken_at >= w.started_at
          union all
          select max(s.updated_at) from public.step_states s
           where s.session_id = w.session_id and s.student_email = w.student_email and s.updated_at >= w.started_at
        ) x
    ) a on true
   where w.ended_at is null
     and not exists (
           select 1 from public.student_presence sp
            where lower(sp.student_email) = lower(w.student_email)
              and sp.last_seen > now() - interval '20 minutes');
$$;


--
-- Name: pia_is_final_format(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_is_final_format(p_kind text, p_text text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $_$
  select case when p_kind = 'percentage'
              then btrim(coalesce(p_text, '')) ~ '^[+-]?(\d+(\.\d+)?|\.\d+)\s*%?$'
              else btrim(coalesce(p_text, '')) ~ '^[+-]?(\d+(\.\d+)?|\.\d+)$' end;
$_$;


--
-- Name: pia_learning_features_calc(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_learning_features_calc(p_session_id uuid, p_email text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_n int; v_correct int; v_steps int; v_hinted int; v_streak int; v_last boolean;
  v_acc numeric; v_attempts numeric; v_hint_rate numeric; v_eff numeric; v_time numeric;
  v_cc int := 0; v_cw int := 0;
begin
  -- The last eight submissions of the session, newest first (rn = 1).
  with recent as (
    select row_number() over (order by e.id desc)::int as rn,
           e.outcome in ('needs_final', 'step_done', 'question_done') as correct,
           least(300, greatest(0, extract(epoch from (e.happened_at - coalesce(
             (select max(p.at) from (
                select pe.happened_at as at from public.step_events pe
                 where pe.session_id = e.session_id and pe.student_email = e.student_email
                   and pe.id < e.id
                 union all
                select sh.taken_at from public.step_hints sh
                 where sh.session_id = e.session_id and sh.student_email = e.student_email
                   and sh.taken_at < e.happened_at) p),
             (select ps.served_at from public.problem_serves ps
               where ps.session_id = e.session_id and ps.student_email = e.student_email
                 and ps.problem_id = e.problem_id
               order by ps.served_at desc limit 1),
             e.happened_at - interval '120 seconds')))))::numeric as rt,
           e.problem_id, e.step_index,
           (select count(*)::int from public.step_events x
             where x.session_id = e.session_id and x.student_email = e.student_email
               and x.problem_id = e.problem_id and x.step_index = e.step_index and x.id <= e.id
               and x.outcome in ('wrong', 'format_error', 'needs_final', 'step_done', 'question_done'))
             as attempt_no,
           exists (select 1 from public.step_hints h
                    where h.session_id = e.session_id and h.student_email = e.student_email
                      and h.problem_id = e.problem_id and h.step_index = e.step_index) as hinted
      from public.step_events e
     where e.session_id = p_session_id and e.student_email = p_email
       and e.outcome in ('wrong', 'format_error', 'needs_final', 'step_done', 'question_done')
     order by e.id desc
     limit 8
  ), steps as (
    select problem_id, step_index, bool_or(hinted) as hinted, max(attempt_no) as m
      from recent group by problem_id, step_index
  )
  select (select count(*) from recent),
         (select count(*) filter (where correct) from recent),
         (select correct from recent where rn = 1),
         coalesce((select min(rn) from recent
                    where correct is distinct from (select correct from recent where rn = 1)),
                  (select count(*) + 1 from recent)) - 1,
         coalesce((select avg(1.0 / (1.0 + rt / 30.0)) filter (where correct) from recent), 0),
         coalesce((select avg(rt) filter (where correct) from recent), 120),
         (select count(*) from steps),
         (select count(*) filter (where hinted) from steps),
         (select avg(m) from steps)
    into v_n, v_correct, v_last, v_streak, v_eff, v_time, v_steps, v_hinted, v_attempts;

  -- Nothing answered yet: the attached game's own starting values.
  if coalesce(v_n, 0) = 0 then
    return jsonb_build_object('events', 0, 'features', jsonb_build_object(
      'recent_accuracy', 0.5, 'average_attempts', 1, 'hint_rate', 0,
      'average_response_time', 120, 'correct_response_efficiency', 0,
      'consecutive_correct', 0, 'consecutive_wrong', 0));
  end if;

  v_acc := v_correct::numeric / v_n;
  v_attempts := greatest(1, coalesce(v_attempts, 1));
  v_hint_rate := case when v_steps > 0 then v_hinted::numeric / v_steps else 0 end;
  if v_last then v_cc := v_streak; else v_cw := v_streak; end if;

  return jsonb_build_object('events', v_n, 'features', jsonb_build_object(
    'recent_accuracy', round(v_acc, 4),
    'average_attempts', round(v_attempts, 4),
    'hint_rate', round(v_hint_rate, 4),
    'average_response_time', round(v_time, 2),
    'correct_response_efficiency', round(v_eff, 4),
    'consecutive_correct', v_cc,
    'consecutive_wrong', v_cw));
end;
$$;


--
-- Name: pia_mask_answers(text, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_mask_answers(p_text text, p_answers text[]) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $$
declare
  v_out   text := coalesce(p_text, '');
  v_nums  numeric[] := '{}';
  a       text;
  n       text;
  m       text[];
  v_val   numeric;
begin
  foreach a in array coalesce(p_answers, '{}') loop
    n := substring(replace(coalesce(a, ''), ',', '') from '-?\d+(?:\.\d+)?');
    if n is not null then v_nums := v_nums || n::numeric; end if;
  end loop;
  if cardinality(v_nums) = 0 then return v_out; end if;

  -- a number written as a result: after "=", "answer", "result", "equals", "gives", "get(s)"
  for m in
    select regexp_matches(p_text,
      '((?:=|\m(?:answers?|results?|equals?|gives?|gets?)\M)\s*(?:is|are|:|=)?\s*)(-?\d[\d,]*(?:\.\d+)?)(\s*%?)', 'gi')
  loop
    v_val := replace(m[2], ',', '')::numeric;
    if v_val = any (v_nums) then
      v_out := replace(v_out, m[1] || m[2] || m[3], m[1] || '___' || m[3]);
    end if;
  end loop;
  return v_out;
end;
$$;


--
-- Name: pia_neutral_tutor(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_neutral_tutor() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if lower(trim(coalesce(new.group_type, ''))) = 'neutral' then
    new.selected_character := 'pia-neutral';
  elsif tg_op = 'UPDATE'
        and lower(trim(coalesce(old.group_type, ''))) = 'neutral'
        and lower(trim(coalesce(new.group_type, ''))) is distinct from 'neutral'
        and old.selected_character = 'pia-neutral'
        and new.selected_character is not distinct from old.selected_character then
    new.selected_character := null;
  end if;
  return new;
end;
$$;


--
-- Name: pia_number_key(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_number_key(p_number text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$ select regexp_replace(coalesce(p_number, ''), '[^0-9]', '', 'g') $$;


--
-- Name: pia_on_password_changed(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_on_password_changed() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  -- Runs as the function owner, so the 0001 write guard lets it through:
  -- that guard only polices writes arriving as `authenticated`.
  update public.profiles
     set must_change_password = false
   where lower(email) = lower(new.email)
     and must_change_password;
  return null;   -- AFTER trigger: the return value is ignored
end;
$$;


--
-- Name: pia_parse_hint(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_parse_hint(p_hint text) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $$
declare j jsonb;
begin
  if p_hint is null or trim(p_hint) = '' then
    return jsonb_build_object('defaultHint', '', 'steps', '[]'::jsonb);
  end if;
  begin
    j := p_hint::jsonb;
  exception when others then
    return jsonb_build_object('defaultHint', p_hint, 'steps', '[]'::jsonb);
  end;
  if jsonb_typeof(j) <> 'object' then
    return jsonb_build_object('defaultHint', p_hint, 'steps', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'defaultHint', coalesce(j ->> 'defaultHint', ''),
    'steps', case when jsonb_typeof(j -> 'steps') = 'array' then j -> 'steps' else '[]'::jsonb end);
end;
$$;


--
-- Name: pia_protect_admin_target(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_protect_admin_target(p_target text, p_action text) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_actor  text := lower(nullif(auth.jwt() ->> 'email', ''));
  v_target text := lower(trim(coalesce(p_target, '')));
begin
  if v_actor is null or v_target = '' or v_target = v_actor then
    return;   -- the owner, or one's own account (each RPC's own rules apply)
  end if;
  if exists (select 1 from public.profiles
              where lower(email) = v_target and lower(trim(coalesce(role, ''))) = 'admin') then
    perform public.pia_refuse(v_actor, p_action || ' another administrator', v_target);
  end if;
end;
$$;


--
-- Name: pia_question_hint_list(jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_question_hint_list(p_steps jsonb, p_default text) RETURNS TABLE(idx integer, step integer, steps_total integer, tier integer, step_prompt text, hint text)
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $$
declare
  v_steps jsonb := case when jsonb_typeof(p_steps) = 'array' then p_steps else '[]'::jsonb end;
  v_total int;
  v_n     int := 0;
  v_step  jsonb;
  v_text  text;
  i       int;
  t       int;
begin
  v_total := jsonb_array_length(v_steps);
  for i in 0 .. v_total - 1 loop
    v_step := v_steps -> i;
    for t in 1 .. 3 loop
      v_text := nullif(trim(coalesce(v_step ->> ('hint' || t), '')), '');
      if v_text is not null then
        v_n := v_n + 1;
        idx := v_n;
        step := i + 1;
        steps_total := v_total;
        tier := t;
        step_prompt := nullif(trim(coalesce(v_step ->> 'prompt', '')), '');
        hint := v_text;
        return next;
      end if;
    end loop;
  end loop;

  if v_n = 0 and nullif(trim(coalesce(p_default, '')), '') is not null then
    idx := 1; step := null; steps_total := 0; tier := 1; step_prompt := null; hint := trim(p_default);
    return next;
  end if;
end;
$$;


--
-- Name: served_questions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.served_questions (
    session_id uuid NOT NULL,
    student_email text NOT NULL,
    problem_id text NOT NULL,
    problem_number integer NOT NULL,
    question_id bigint NOT NULL,
    topic integer NOT NULL,
    student_topic integer NOT NULL,
    question text NOT NULL,
    final_answer text NOT NULL,
    steps jsonb DEFAULT '[]'::jsonb NOT NULL,
    default_hint text,
    served_at timestamp with time zone DEFAULT now() NOT NULL,
    base_points integer
);


--
-- Name: pia_question_payload(public.served_questions); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_question_payload(p public.served_questions) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_total    int;
  v_used     int;
  v_attempts int;
  v_correct  boolean;
  v_hints    jsonb;
begin
  select count(*) into v_total from public.pia_question_hint_list(p.steps, p.default_hint);

  select count(*) into v_used
    from public.hint_consumptions h
   where h.session_id = p.session_id and h.student_email = p.student_email and h.problem_id = p.problem_id;

  select count(*), coalesce(bool_or(a.was_correct), false) into v_attempts, v_correct
    from public.question_attempts a
   where a.session_id = p.session_id and a.student_email = p.student_email and a.problem_id = p.problem_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'index', l.idx, 'step', l.step, 'steps_total', l.steps_total,
           'tier', l.tier, 'tier_label', public.pia_tier_label(l.tier),
           'step_prompt', l.step_prompt, 'text', l.hint) order by l.idx), '[]'::jsonb)
    into v_hints
    from public.pia_question_hint_list(p.steps, p.default_hint) l
   where l.idx <= v_used;

  return jsonb_build_object(
    'done',            false,
    'problem_id',      p.problem_id,
    'problem_number',  p.problem_number,
    'question',        p.question,
    'topic',           p.student_topic,
    'question_topic',  p.topic,
    'hints_total',     v_total,
    'hints_used',      v_used,
    'hints_left',      greatest(v_total - v_used, 0),
    'hints',           v_hints,
    'attempts_used',   v_attempts,
    'attempts_left',   case when v_correct then 0 else greatest(2 - v_attempts, 0) end,
    'locked',          v_correct or v_attempts >= 2);
end;
$$;


--
-- Name: pia_record_stage_grant(text, text, text[], jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_record_stage_grant(p_stage text, p_section text, p_emails text[], p_result jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_section text := nullif(trim(coalesce(p_section, '')), '');
  v_granted int;
begin
  if v_section is null or p_stage is null or p_result is null then
    return p_result;
  end if;

  v_granted := case when jsonb_typeof(p_result -> 'granted') = 'array'
                    then jsonb_array_length(p_result -> 'granted') else 0 end;

  -- Nobody let in = no override to show. An earlier grant for the section,
  -- if any, is left as it was.
  if v_granted > 0 then
    insert into public.stage_overrides (stage, section, granted_count, granted_by, granted_at)
    values (p_stage, v_section, v_granted, lower(nullif(auth.jwt() ->> 'email', '')), now())
    on conflict (stage, section) do update
      set granted_count = excluded.granted_count,
          granted_by    = excluded.granted_by,
          granted_at    = excluded.granted_at;
  end if;

  return p_result;
end;
$$;


--
-- Name: pia_refuse(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_refuse(p_actor text, p_what text, p_target text) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  -- Survives the rollback the exception below causes: the Postgres log.
  raise warning 'PIA security: refused "%" by % on %', p_what, coalesce(p_actor, 'owner'), coalesce(p_target, '-');
  raise exception 'PIA: an administrator cannot %. Only the project owner can, from the Supabase dashboard.', p_what
    using errcode = '42501';
end;
$$;


--
-- Name: pia_registration_rules(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_registration_rules() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if lower(trim(coalesce(new.role, 'student'))) = 'student' then
    if tg_op = 'INSERT'
       and (new.parental_consent is not true or new.student_assent is not true) then
      raise exception 'PIA: a student cannot be registered without both parental consent and student assent.'
        using errcode = 'P0001';
    end if;
    new.max_devices := 1;
  end if;
  return new;
end;
$$;


--
-- Name: pia_replay_decision_tree(text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_replay_decision_tree(p_classifications text[]) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    AS $$
declare
  v_level int := 1;
  v_cc    int := 0;
  v_ss    int := 0;
  c       text;
begin
  foreach c in array coalesce(p_classifications, array[]::text[]) loop
    if c = 'smooth' then
      v_cc := v_cc + 1;
      v_ss := 0;
      if v_cc >= 3 and v_level < 3 then
        v_level := v_level + 1;
        v_cc := 0;
      end if;
    else
      v_cc := 0;
      v_ss := v_ss + 1;
      if v_ss >= 2 and v_level > 1 then
        v_level := v_level - 1;
        v_ss := 0;
      end if;
    end if;
  end loop;

  return jsonb_build_object('level', v_level, 'consecutive_correct', v_cc, 'struggling_streak', v_ss);
end;
$$;


--
-- Name: pia_require_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_require_admin() RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if public.pia_caller_role() is distinct from 'admin' or not public.jwt_is_current() then
    raise exception 'PIA: only an administrator can do this.' using errcode = '42501';
  end if;
end;
$$;


--
-- Name: pia_result_payload(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_result_payload(p_session_id uuid, p_email text, p_problem_id text) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  t        record;
  v_reason text;
  v_streak int := 0;
  v_count  int;
  r        record;
begin
  select * into t from public.tutoring_attempts
   where session_id = p_session_id and student_email = p_email and problem_id = p_problem_id;
  if not found then return null; end if;

  select c.reason into v_reason from public.topic_changes c
   where c.session_id = p_session_id and c.student_email = p_email and c.problem_number = t.problem_number
   order by c.id desc limit 1;

  for r in select a.is_correct from public.tutoring_attempts a
            where a.session_id = p_session_id and a.student_email = p_email and a.problem_id like 'qb-%'
            order by a.problem_number desc loop
    exit when not r.is_correct;
    v_streak := v_streak + 1;
  end loop;

  select count(*) into v_count from public.tutoring_attempts a
   where a.session_id = p_session_id and a.student_email = p_email and a.problem_id like 'qb-%';

  return jsonb_build_object(
    'is_correct',        t.is_correct,
    'classification',    t.classification,
    'attempts_used',     t.attempts_used,
    'hints_used',        t.hints_used,
    'time_taken_ms',     t.time_taken_ms,
    'topic_before',      t.level_before,
    'topic',             t.level_after,
    'topic_change',      case when t.level_after > t.level_before then 'up'
                              when t.level_after < t.level_before then 'down' end,
    'reason',            v_reason,
    'streak',            v_streak,
    'problems_answered', v_count);
end;
$$;


--
-- Name: pia_session_state(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_session_state(p_session_id uuid, p_email text) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  select public.pia_replay_decision_tree(
    coalesce(array_agg(t.classification order by t.problem_number), array[]::text[]))
  from public.tutoring_attempts t
  where t.session_id = p_session_id and t.student_email = p_email;
$$;


--
-- Name: pia_settle_test_score(text, boolean, numeric, numeric, numeric, numeric, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_settle_test_score(p_label text, p_insert boolean, p_raw numeric, p_max numeric, p_score numeric, p_old_raw numeric, p_old_max numeric, p_old_score numeric) RETURNS numeric
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  -- No raw data.
  if p_raw is null and p_max is null then
    -- The raw data was just cleared: the score it produced goes with it.
    if not p_insert and (p_old_raw is not null or p_old_max is not null)
       and p_score is not distinct from p_old_score then
      return null;
    end if;
    -- A new score typed on its own (an old console, or a direct write).
    if p_score is not null and (p_insert or p_score is distinct from p_old_score) then
      raise exception 'PIA: the % score is calculated from the raw score and the highest possible score -- enter both. (If the console asks for a single score, reload it.)', p_label
        using errcode = '22023';
    end if;
    -- Blank, or a score entered before 0034, kept as it was.
    return p_score;
  end if;

  if p_raw is null or p_max is null then
    raise exception 'PIA: enter both the raw score and the highest possible score for the %.', p_label
      using errcode = '22023';
  end if;
  if p_max <= 0 then
    raise exception 'PIA: the highest possible score for the % must be more than 0.', p_label
      using errcode = '22023';
  end if;
  if p_raw < 0 or p_raw > p_max then
    raise exception 'PIA: the % raw score must be between 0 and the highest possible score (%).', p_label, p_max
      using errcode = '22023';
  end if;

  -- New raw data: calculate.
  if p_insert or p_raw is distinct from p_old_raw or p_max is distinct from p_old_max then
    return public.pia_transmute(p_raw, p_max);
  end if;

  -- Raw data unchanged. The stored score is left exactly as it is -- a
  -- student's own heartbeat update must not rewrite it -- and cannot be
  -- overwritten by hand.
  if p_score is distinct from p_old_score then
    raise exception 'PIA: the % score is calculated from the raw score -- change the raw score instead.', p_label
      using errcode = '22023';
  end if;
  return p_old_score;
end;
$$;


--
-- Name: pia_stage_open(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_stage_open(p_key text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(
    (select trim(both '"' from s.value::text) = 'true'
     from public.settings s where s.key = p_key limit 1),
    false);
$$;


--
-- Name: pia_stamp_base_points(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_stamp_base_points() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.base_points is null then
    select q.points into new.base_points from public.question_bank q where q.id = new.question_id;
  end if;
  return new;
end;
$$;


--
-- Name: pia_step_confirm_kind(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_step_confirm_kind(p_topic integer, p_idx integer) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  select case when public.pia_step_label(p_topic, p_idx) = 'Conversion'
              then (case when p_topic = 1 then 'decimal' else 'percentage' end)
              else 'number' end;
$$;


--
-- Name: pia_step_hints(jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_step_hints(p_step jsonb, p_default text) RETURNS text[]
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $$
declare
  r text[] := '{}';
  t int;
  v text;
begin
  for t in 1 .. 3 loop
    v := nullif(trim(coalesce(p_step ->> ('hint' || t), '')), '');
    if v is not null then r := r || v; end if;
  end loop;

  if cardinality(r) = 0 and jsonb_typeof(p_step -> 'hints') = 'array' then
    select coalesce(array_agg(trim(e.v) order by e.ord) filter (where nullif(trim(e.v), '') is not null), '{}')
      into r
      from jsonb_array_elements_text(p_step -> 'hints') with ordinality as e(v, ord);
  end if;

  if cardinality(r) = 0 then
    r := array[coalesce(nullif(trim(coalesce(p_default, '')), ''), 'Check your calculations carefully.')];
  end if;
  return r;
end;
$$;


--
-- Name: pia_step_label(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_step_label(p_topic integer, p_idx integer) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  select case when p_topic = 1 then (array['Conversion', 'Multiplication'])[p_idx + 1]
              else (array['Subtraction', 'Division', 'Conversion'])[p_idx + 1] end;
$$;


--
-- Name: pia_step_matches(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_step_matches(p_submitted text, p_key text) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  u numeric := public.pia_eval_expr(p_submitted);
  k numeric := public.pia_eval_expr(p_key);
begin
  if u is not null and k is not null then
    return abs(u - k) <= 0.001;
  end if;
  return lower(trim(coalesce(p_submitted, ''))) = lower(trim(coalesce(p_key, '')));
end;
$$;


--
-- Name: pia_step_required(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_step_required(p_topic integer) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
  select case when p_topic = 1 then 2 else 3 end;
$$;


--
-- Name: step_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.step_states (
    session_id uuid NOT NULL,
    student_email text NOT NULL,
    problem_id text NOT NULL,
    step_index integer DEFAULT 0 NOT NULL,
    stage text DEFAULT 'work'::text NOT NULL,
    work_text text,
    wrong_streak integer DEFAULT 0 NOT NULL,
    hint_tier integer DEFAULT 0 NOT NULL,
    errors integer DEFAULT 0 NOT NULL,
    hints integer DEFAULT 0 NOT NULL,
    hint_unlocked boolean DEFAULT false NOT NULL,
    done_steps jsonb DEFAULT '[]'::jsonb NOT NULL,
    completed boolean DEFAULT false NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    passed boolean,
    score integer,
    CONSTRAINT step_states_stage_check CHECK ((stage = ANY (ARRAY['work'::text, 'confirm'::text])))
);


--
-- Name: pia_step_state_json(public.served_questions, public.step_states); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_step_state_json(sq public.served_questions, st public.step_states) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select jsonb_build_object(
    'done',           false,
    'problem_id',     sq.problem_id,
    'problem_number', sq.problem_number,
    'question',       sq.question,
    'topic',          sq.student_topic,
    'question_topic', sq.topic,
    'steps_total',    public.pia_step_required(sq.topic),
    'step_labels',    (select jsonb_agg(public.pia_step_label(sq.topic, g - 1) order by g)
                         from generate_series(1, public.pia_step_required(sq.topic)) g),
    'current_step',   st.step_index,
    'stage',          st.stage,
    'confirm_kind',   case when st.stage = 'confirm'
                           then public.pia_step_confirm_kind(sq.topic, st.step_index) end,
    'work_text',      st.work_text,
    'done_steps',     st.done_steps,
    'wrong_streak',   st.wrong_streak,
    'hint_unlocked',  st.hint_unlocked,
    'hint_tier',      st.hint_tier,
    'errors',         st.errors,
    'hints_used',     st.hints,
    'locked',         st.completed);
$$;


--
-- Name: pia_steps_valid(jsonb, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_steps_valid(p_steps jsonb, p_topic integer) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $$
declare
  n int := public.pia_step_required(p_topic);
  i int;
begin
  if p_steps is null or jsonb_typeof(p_steps) <> 'array' or jsonb_array_length(p_steps) < n then
    return false;
  end if;
  for i in 0 .. n - 1 loop
    if nullif(trim(coalesce(p_steps -> i ->> 'answer', p_steps -> i ->> 'stepAnswer', '')), '') is null then
      return false;
    end if;
  end loop;
  return true;
end;
$$;


--
-- Name: pia_student_topic(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_student_topic(p_email text) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare v_topic int;
begin
  insert into public.student_topic_progress (student_email) values (p_email)
  on conflict (student_email) do nothing;
  select topic into v_topic from public.student_topic_progress where student_email = p_email;
  return coalesce(v_topic, 1);
end;
$$;


--
-- Name: pia_sync_professor(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_sync_professor(p_email text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_first text;
begin
  select ps.section into v_first from public.professor_sections ps where ps.email = v_email order by ps.section limit 1;
  update public.professors set assigned_section = v_first where lower(email) = v_email;
  update public.profiles p
     set section = case when exists (select 1 from public.professor_sections ps where ps.email = v_email and ps.section = p.section)
                        then p.section else v_first end
   where lower(p.email) = v_email and lower(trim(coalesce(p.role, ''))) = 'teacher';
end;
$$;


--
-- Name: pia_tier_label(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_tier_label(p_tier integer) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  select case p_tier when 1 then 'Concept' when 2 then 'Setup' when 3 then 'Worked calculation' else 'Hint' end;
$$;


--
-- Name: pia_topic_rules(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_topic_rules(p_topic integer, OUT mastery integer, OUT min_q integer, OUT max_err integer) RETURNS record
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
begin
  select coalesce(case p_topic when 1 then c.easy_mastery when 2 then c.medium_mastery else c.hard_mastery end, 80),
         coalesce(case p_topic when 1 then c.easy_min_questions when 2 then c.medium_min_questions else c.hard_min_questions end, 3),
         coalesce(case p_topic when 1 then c.easy_max_errors when 2 then c.medium_max_errors else c.hard_max_errors end, 3)
    into mastery, min_q, max_err
    from public.app_config c where c.id = 1;
  if not found then
    mastery := 80; min_q := 3; max_err := 3;
  end if;
end;
$$;


--
-- Name: pia_touch_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


--
-- Name: pia_transmute(numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_transmute(p_raw numeric, p_max numeric) RETURNS numeric
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
  select round(p_raw / p_max * 50 + 50, 2);
$$;


--
-- Name: pia_tutoring_closed(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_tutoring_closed() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select public.pia_tutoring_closed_for(auth.jwt() ->> 'email');
$$;


--
-- Name: pia_tutoring_closed_for(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_tutoring_closed_for(p_email text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce((
    select (t.opens_at is not null and t.opens_at > now())
        or (t.closes_at is not null and t.closes_at <= now())
      from public.profiles p
      join public.tutoring_schedule t on t.section = nullif(trim(p.section), '')
     where lower(p.email) = lower(p_email)
     limit 1), false);
$$;


--
-- Name: pia_window_expired(public.game_windows); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pia_window_expired(w public.game_windows) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  select public.pia_tutoring_closed_for(w.student_email);
$$;


--
-- Name: professors_claim_section(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.professors_claim_section() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_section text := nullif(trim(coalesce(new.assigned_section, '')), '');
begin
  if v_section is null then return new; end if;
  if exists (select 1 from public.professor_sections ps where ps.section = v_section and ps.email <> lower(new.email)) then
    raise exception 'That section already has a professor.' using errcode = 'P0001';
  end if;
  insert into public.professor_sections (email, section) values (lower(new.email), v_section) on conflict do nothing;
  return new;
end;
$$;


--
-- Name: profiles_guard_privileged_columns(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.profiles_guard_privileged_columns() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
    if exists (
        select 1 from public.profiles
        where email = auth.jwt() ->> 'email'
          and lower(trim(role)) = 'admin'
    ) then
        return new;
    end if;

    new.role            := old.role;
    new.group_type      := old.group_type;
    new.pre_test_score  := old.pre_test_score;
    new.post_test_score := old.post_test_score;
    new.max_devices     := old.max_devices;
    new.email           := old.email;
    new.section         := old.section;
    return new;
end;
$$;


--
-- Name: record_heartbeat(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_heartbeat(p_stage text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  v_row     public.student_stage_time%rowtype;
  v_locked  timestamptz;
  v_gap     numeric;
  v_credit  integer := 0;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  -- Only students are timed; a staff ping is simply ignored.
  if public.pia_caller_role() is distinct from 'student' then
    return jsonb_build_object('counted', false, 'reason', 'not_a_student');
  end if;

  if p_stage is null or p_stage not in ('OCEAN', 'Character Selection', 'Tutoring Dashboard') then
    return jsonb_build_object('counted', false, 'reason', 'unknown_stage');
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    return jsonb_build_object('counted', false, 'reason', 'no_profile');
  end if;

  -- A stage the student has already finished takes no more time.
  if not public.pia_can_enter_stage(v_profile.is_ocean_done, v_profile.group_type,
                                    v_profile.selected_character, p_stage) then
    return jsonb_build_object('counted', false, 'reason', 'stage_completed');
  end if;

  insert into public.student_stage_time (student_email) values (v_profile.email)
  on conflict (student_email) do nothing;

  select * into v_row from public.student_stage_time
   where student_email = v_profile.email for update;

  v_locked := case p_stage when 'OCEAN' then v_row.ocean_time_locked_at
                           when 'Character Selection' then v_row.character_select_time_locked_at
                           else v_row.tutoring_time_locked_at end;
  if v_locked is not null then
    return jsonb_build_object('counted', false, 'reason', 'locked', 'locked', true);
  end if;

  if v_row.last_heartbeat_timestamp is not null and v_row.heartbeat_stage = p_stage then
    v_gap := extract(epoch from (now() - v_row.last_heartbeat_timestamp));
    if v_gap < 10 then
      return jsonb_build_object('counted', false, 'reason', 'too_soon');
    elsif v_gap <= 45 then
      v_credit := least(30, floor(v_gap))::integer;
    end if;
  end if;

  update public.student_stage_time set
    ocean_time            = ocean_time + case when p_stage = 'OCEAN' then v_credit else 0 end,
    character_select_time = character_select_time + case when p_stage = 'Character Selection' then v_credit else 0 end,
    tutoring_time         = tutoring_time + case when p_stage = 'Tutoring Dashboard' then v_credit else 0 end,
    heartbeat_stage       = p_stage,
    last_heartbeat_timestamp = now()
   where student_email = v_profile.email
  returning * into v_row;

  return jsonb_build_object(
    'counted', v_credit > 0,
    'credited', v_credit,
    'seconds', case p_stage when 'OCEAN' then v_row.ocean_time
                            when 'Character Selection' then v_row.character_select_time
                            else v_row.tutoring_time end);
end;
$$;


--
-- Name: record_problem_result(uuid, text, integer, integer, integer, integer, integer, integer, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_problem_result(p_session_id uuid, p_problem_id text, p_problem_number integer, p_level_before integer, p_level_after integer, p_attempts_used integer, p_hints_used integer, p_time_taken_ms integer, p_final_answer numeric, p_classification text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    v_email text := auth.jwt() ->> 'email';
    v_key   numeric;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

    if v_email is null then
        raise exception 'Not authenticated.';
    end if;

    select answer into v_key 
    from public.math_answers
    where problem_id = p_problem_id;

    if not found then
        raise exception 'Unknown problem_id: %', p_problem_id;
    end if;

    insert into public.tutoring_attempts (
        session_id, student_email, problem_id, problem_number,
        level_before, level_after, attempts_used, hints_used,
        time_taken_ms, is_correct, classification
    ) values (
        p_session_id,
        v_email,
        p_problem_id,
        greatest(1, least(50,      p_problem_number)),
        greatest(1, least(3,       p_level_before)),
        greatest(1, least(3,       p_level_after)),
        greatest(0, least(10,      p_attempts_used)),
        greatest(0, least(10,      p_hints_used)),
        greatest(0, least(3600000, p_time_taken_ms)),
        (p_final_answer is not null and p_final_answer = v_key),
        case when p_classification = 'smooth' then 'smooth' else 'struggling' end
    )
    on conflict (session_id, problem_number) do nothing;
end;
$$;


--
-- Name: record_problem_result_v2(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_problem_result_v2(p_session_id uuid, p_problem_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email    text := auth.jwt() ->> 'email';
  v_attempts int;
  v_correct  boolean;
  v_hints    int;
  v_served   timestamptz;
  v_last     timestamptz;
  v_ms       bigint;
  v_number   int;
  v_class    text;
  v_before   jsonb;
  v_after    jsonb;
  v_smooth   boolean;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  -- (a) Attempts at pagkatama -- mula sa math_attempt_log, isinulat mismo ng
  --     check_math_answer. Hindi ito naaabot ng client.
  select count(*), coalesce(bool_or(was_correct), false), max(attempted_at)
    into v_attempts, v_correct, v_last
    from public.math_attempt_log
   where student_email = v_email and session_id = p_session_id and problem_id = p_problem_id;

  -- (b) Hints -- server-owned counter, hindi na ang p_hints_used ng browser.
  select count(*) into v_hints
    from public.hint_consumptions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  -- (c) Timing -- mula sa serve stamp, hindi sa Date.now() ng browser.
  select served_at, problem_number into v_served, v_number
    from public.problem_serves
   where session_id = p_session_id and problem_id = p_problem_id;

  if v_served is null then
    raise exception 'PIA: this problem has not been served yet.' using errcode = '42501';
  end if;

  v_ms := greatest(0, least(3600000,
            (extract(epoch from (coalesce(v_last, now()) - v_served)) * 1000)::bigint));

  -- (d) Classification -- eksaktong rule ng tutoring-dashboard.js, sa server:
  --     smooth = tama, walang hint, walang retry, at <= 30s.
  v_smooth := v_correct and v_hints = 0 and v_attempts <= 1 and v_ms <= 30000;
  v_class  := case when v_smooth then 'smooth' else 'struggling' end;

  -- (e) Level -- ni-replay mula sa naitalang kasaysayan ng session.
  v_before := public.pia_session_state(p_session_id, v_email);
  v_after  := public.pia_replay_decision_tree(
                (select coalesce(array_agg(t.classification order by t.problem_number), array[]::text[])
                   from public.tutoring_attempts t
                  where t.session_id = p_session_id and t.student_email = v_email)
                || array[v_class]);

  insert into public.tutoring_attempts (
    session_id, student_email, problem_id, problem_number,
    level_before, level_after, attempts_used, hints_used,
    time_taken_ms, is_correct, classification)
  values (
    p_session_id, v_email, p_problem_id, coalesce(v_number, 1),
    (v_before ->> 'level')::int, (v_after ->> 'level')::int,
    least(10, v_attempts), least(10, v_hints),
    v_ms, v_correct, v_class)
  on conflict (session_id, problem_number) do nothing;

  return jsonb_build_object(
    'is_correct',          v_correct,
    'classification',      v_class,
    'attempts_used',       v_attempts,
    'hints_used',          v_hints,
    'time_taken_ms',       v_ms,
    'level_before',        (v_before ->> 'level')::int,
    'level',               (v_after ->> 'level')::int,
    'consecutive_correct', (v_after ->> 'consecutive_correct')::int,
    'levelled_up',         (v_after ->> 'level')::int > (v_before ->> 'level')::int);
end;
$$;


--
-- Name: record_question_result(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_question_result(p_session_id uuid, p_problem_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_sq      public.served_questions%rowtype;
  v_att     int;
  v_ok      boolean;
  v_last    timestamptz;
  v_hints   int;
  v_served  timestamptz;
  v_ms      bigint;
  v_class   text;
  v_cfg     public.app_config%rowtype;
  v_prog    public.student_topic_progress%rowtype;
  v_mastery int;
  v_min     int;
  v_maxerr  int;
  v_from    int;
  v_to      int;
  v_reason  text;
  v_a       int;
  v_c       int;
  v_w       int;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  if not found then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  if exists (select 1 from public.tutoring_attempts
              where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id) then
    return public.pia_result_payload(p_session_id, v_email, p_problem_id);
  end if;

  -- (a) Attempts and correctness -- written only by check_question_answer.
  select count(*), coalesce(bool_or(was_correct), false), max(attempted_at)
    into v_att, v_ok, v_last
    from public.question_attempts
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  if not (v_ok or v_att >= 2) then
    raise exception 'PIA: answer this question first.' using errcode = '42501';
  end if;

  -- (b) Hints -- the server's own count.
  select count(*) into v_hints from public.hint_consumptions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  -- (c) Time -- from the serve stamp, never the browser's clock.
  select served_at into v_served from public.problem_serves
   where session_id = p_session_id and problem_id = p_problem_id;
  if v_served is null then
    raise exception 'PIA: this question was not served.' using errcode = '42501';
  end if;
  v_ms := greatest(0, least(3600000,
            (extract(epoch from (coalesce(v_last, now()) - v_served)) * 1000)::bigint));

  -- (d) Classification -- the same rule as every earlier session.
  v_class := case when v_ok and v_hints = 0 and v_att <= 1 and v_ms <= 30000
                  then 'smooth' else 'struggling' end;

  -- (e) Topic -- the admin's rules for the student's CURRENT topic.
  select * into v_cfg from public.app_config where id = 1;

  insert into public.student_topic_progress (student_email) values (v_email)
  on conflict (student_email) do nothing;
  select * into v_prog from public.student_topic_progress where student_email = v_email for update;

  v_from := v_prog.topic;
  v_a := v_prog.stint_answered + 1;
  v_c := v_prog.stint_correct + case when v_ok then 1 else 0 end;
  v_w := v_prog.stint_wrong + case when v_ok then 0 else 1 end;

  v_mastery := coalesce(case v_from when 1 then v_cfg.easy_mastery
                                    when 2 then v_cfg.medium_mastery
                                    else v_cfg.hard_mastery end, 80);
  v_min     := coalesce(case v_from when 1 then v_cfg.easy_min_questions
                                    when 2 then v_cfg.medium_min_questions
                                    else v_cfg.hard_min_questions end, 3);
  v_maxerr  := coalesce(case v_from when 1 then v_cfg.easy_max_errors
                                    when 2 then v_cfg.medium_max_errors
                                    else v_cfg.hard_max_errors end, 3);

  v_to := v_from;
  v_reason := null;
  if v_from < 3 and v_c >= v_min and v_c * 100 >= v_mastery * v_a then
    v_to := v_from + 1;
    v_reason := 'mastered';
  elsif v_w >= v_maxerr then
    if v_from > 1 then
      v_to := v_from - 1;
      v_reason := 'error_limit';
    else
      v_reason := 'floor_reset';
    end if;
  end if;

  if v_reason is not null then
    insert into public.topic_changes (
      student_email, session_id, problem_number, from_topic, to_topic, reason,
      stint_answered, stint_correct, stint_wrong, mastery, min_solved, max_errors)
    values (
      v_email, p_session_id, v_sq.problem_number, v_from, v_to, v_reason,
      v_a, v_c, v_w, v_mastery, v_min, v_maxerr);

    update public.student_topic_progress
       set topic = v_to, stint_answered = 0, stint_correct = 0, stint_wrong = 0, updated_at = now()
     where student_email = v_email;
  else
    update public.student_topic_progress
       set stint_answered = v_a, stint_correct = v_c, stint_wrong = v_w, updated_at = now()
     where student_email = v_email;
  end if;

  -- level_before / level_after now hold the TOPIC (1-3) for these rows.
  insert into public.tutoring_attempts (
    session_id, student_email, problem_id, problem_number,
    level_before, level_after, attempts_used, hints_used,
    time_taken_ms, is_correct, classification)
  values (
    p_session_id, v_email, p_problem_id, v_sq.problem_number,
    v_from, v_to, least(10, v_att), least(10, v_hints),
    v_ms, v_ok, v_class)
  on conflict (session_id, problem_number) do nothing;

  return public.pia_result_payload(p_session_id, v_email, p_problem_id);
end;
$$;


--
-- Name: release_device(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.release_device(p_device_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_email text := auth.jwt() ->> 'email';
begin
    if v_email is null then return; end if;
    update public.profiles
       set active_devices  = coalesce(array_remove(active_devices, p_device_id), '{}'),
           device_sessions = coalesce(device_sessions, '{}'::jsonb) - p_device_id
     where email = v_email;
end;
$$;


--
-- Name: reset_my_devices(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reset_my_devices(p_device_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email   text   := auth.jwt() ->> 'email';
  v_uid     uuid   := nullif(auth.jwt() ->> 'sub', '')::uuid;
  v_sid     uuid   := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_iat     bigint := nullif(auth.jwt() ->> 'iat', '')::bigint;
  v_device  text   := trim(coalesce(p_device_id, ''));
  v_fresh   boolean;
begin
  if v_email is null or v_uid is null or v_iat is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  if v_device = '' or length(v_device) > 120 then
    raise exception 'PIA: a device id is required.' using errcode = '22023';
  end if;

  -- The mailbox proof: an email-based sign-in on this session, recently.
  select exists (
    select 1
      from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) as m
     where m ->> 'method' in ('otp', 'magiclink', 'recovery', 'invite', 'email/signup')
       and nullif(m ->> 'timestamp', '')::bigint >= extract(epoch from now())::bigint - 900
  ) into v_fresh;

  if not v_fresh then
    raise exception 'PIA: confirm it is you with the code from your email first.' using errcode = '42501';
  end if;

  -- Every token issued before this one is now stale; this one is not.
  update public.profiles
     set sessions_revoked_at = greatest(coalesce(sessions_revoked_at, '-infinity'::timestamptz),
                                        to_timestamp(v_iat)),
         active_devices = array[v_device], device_sessions = jsonb_build_object(v_device, v_sid::text)
   where email = v_email;

  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  -- The other devices' sessions and refresh tokens go; this session stays.
  -- (With no session_id claim there is nothing to spare, so all go -- this
  -- device then keeps working until its current token expires.)
  delete from auth.sessions
   where user_id = v_uid and (v_sid is null or id <> v_sid);
  delete from auth.refresh_tokens
   where user_id = v_uid::text and (v_sid is null or session_id is distinct from v_sid);

  return jsonb_build_object('ok', true, 'devices', array[v_device]);
end;
$$;


--
-- Name: respond_topic_offer(uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.respond_topic_offer(p_session_id uuid, p_problem_id text, p_accept boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email text;
  v_off   public.topic_offers%rowtype;
  v_prog  public.student_topic_progress%rowtype;
  v_rule  record;
  v_to    int;
begin
  v_email := public.pia_game_email();
  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_off from public.topic_offers
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
   for update;
  if not found then
    raise exception 'PIA: there is no offer to answer.' using errcode = '42501';
  end if;
  if v_off.status <> 'pending' then
    return jsonb_build_object('topic', public.pia_student_topic(v_email), 'status', v_off.status);
  end if;

  select * into v_prog from public.student_topic_progress where student_email = v_email for update;
  select * into v_rule from public.pia_topic_rules(v_off.from_topic);
  v_to := case when p_accept then v_off.target_topic else v_off.from_topic end;

  insert into public.topic_changes (
    student_email, session_id, problem_number, from_topic, to_topic, reason,
    stint_answered, stint_correct, stint_wrong, mastery, min_solved, max_errors)
  values (
    v_email, p_session_id,
    (select problem_number from public.served_questions
      where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id),
    v_off.from_topic, v_to,
    (case when p_accept then 'accepted_' else 'refused_' end) || v_off.offer,
    v_prog.stint_answered, v_prog.stint_correct, v_prog.failed_streak,
    v_rule.mastery, v_rule.min_q, v_rule.max_err);

  if p_accept then
    -- A new topic starts a fresh window.
    update public.student_topic_progress
       set topic = v_to, stint_answered = 0, stint_correct = 0, failed_streak = 0, updated_at = now()
     where student_email = v_email;
  elsif v_off.offer = 'up' then
    update public.student_topic_progress
       set stint_answered = 0, stint_correct = 0, failed_streak = 0, updated_at = now()
     where student_email = v_email;
  else
    update public.student_topic_progress
       set failed_streak = 0, updated_at = now()
     where student_email = v_email;
  end if;

  update public.topic_offers
     set status = case when p_accept then 'accepted' else 'refused' end, resolved_at = now()
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  return jsonb_build_object('topic', v_to, 'status', case when p_accept then 'accepted' else 'refused' end);
end;
$$;


--
-- Name: restart_after_expiry(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.restart_after_expiry(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email text := public.pia_game_email();
begin
  if public.pia_tutoring_closed() then
    return jsonb_build_object('closed', true, 'restarted', false,
      'clock', jsonb_build_object('closed', true, 'expired', true, 'limit_seconds', 86400, 'remaining_seconds', 0));
  end if;
  return public.serve_next_step_question(p_session_id) || jsonb_build_object('restarted', false);
end;
$$;


--
-- Name: resume_or_start_game_session(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resume_or_start_game_session() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email    text;
  v_session  uuid;
  v_answered int;
  v_correct  int;
  v_pending  text;
  v_streak   int := 0;
  r          record;
begin
  v_email := public.pia_game_email();

  select ps.session_id into v_session
    from public.problem_serves ps
   where ps.student_email = v_email and ps.problem_id like 'qb-%'
   order by ps.served_at desc
   limit 1;

  if v_session is not null then
    select count(*), coalesce(count(*) filter (where is_correct), 0)
      into v_answered, v_correct
      from public.tutoring_attempts
     where session_id = v_session and student_email = v_email and problem_id like 'qb-%';

    if true then   -- no question-count ending: the session continues until the student stops
      select sq.problem_id into v_pending
        from public.served_questions sq
       where sq.session_id = v_session and sq.student_email = v_email
         and not exists (select 1 from public.tutoring_attempts t
                          where t.session_id = sq.session_id and t.student_email = sq.student_email
                            and t.problem_id = sq.problem_id)
       order by sq.problem_number desc
       limit 1;

      -- Time away is not time on task: the open question's clock restarts.
      if v_pending is not null then
        update public.problem_serves set served_at = now()
         where session_id = v_session and problem_id = v_pending;
      end if;

      for r in select a.is_correct from public.tutoring_attempts a
                where a.session_id = v_session and a.student_email = v_email and a.problem_id like 'qb-%'
                order by a.problem_number desc loop
        exit when not r.is_correct;
        v_streak := v_streak + 1;
      end loop;

      return jsonb_build_object(
        'session_id',          v_session,
        'resumed',             true,
        'problems_answered',   v_answered,
        'correct_count',       v_correct,
        'topic',               public.pia_student_topic(v_email),
        'consecutive_correct', v_streak,
        'time_limit_seconds',  coalesce((select c.time_limit * 60 from public.app_config c where c.id = 1), 600),
        'pending_problem_id',  v_pending);
    end if;
  end if;

  return jsonb_build_object(
    'session_id',          public.start_game_session(),
    'resumed',             false,
    'problems_answered',   0,
    'correct_count',       0,
    'topic',               public.pia_student_topic(v_email),
    'consecutive_correct', 0,
    'time_limit_seconds',  coalesce((select c.time_limit * 60 from public.app_config c where c.id = 1), 600),
    'pending_problem_id',  null);
end;
$$;


--
-- Name: reveal_question_solution(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reveal_question_solution(p_session_id uuid, p_problem_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_sq    public.served_questions%rowtype;
  v_att   int;
  v_ok    boolean;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  if not found then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  select count(*), coalesce(bool_or(was_correct), false) into v_att, v_ok
    from public.question_attempts
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  -- The gate: without it this would be the answer leak.
  if not (v_ok or v_att >= 2) then
    raise exception 'PIA: this question is not finished yet.' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'final_answer', v_sq.final_answer,
    'steps', (select coalesce(jsonb_agg(jsonb_build_object(
                       'step', e.ord, 'prompt', e.s ->> 'prompt',
                       'answer', e.s ->> 'answer', 'worked', e.s ->> 'hint3') order by e.ord), '[]'::jsonb)
                from jsonb_array_elements(v_sq.steps) with ordinality as e(s, ord)));
end;
$$;


--
-- Name: reveal_solution(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reveal_solution(p_session_id uuid, p_problem_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email  text := auth.jwt() ->> 'email';
  v_used   int;
  v_ok     boolean;
  v_text   text;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  select count(*), coalesce(bool_or(was_correct), false) into v_used, v_ok
    from public.math_attempt_log
   where student_email = v_email and session_id = p_session_id and problem_id = p_problem_id;

  -- Katulad ng lock rule ng check_math_answer: tama na, o ubos na ang 2 attempts.
  if not (v_ok or v_used >= 2) then
    raise exception 'PIA: this problem is not finished yet.' using errcode = '42501';
  end if;

  select hint_text into v_text
    from public.math_hints where problem_id = p_problem_id order by hint_index desc limit 1;

  return jsonb_build_object('solution', v_text);
end;
$$;


--
-- Name: serve_next_question(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.serve_next_question(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email    text := auth.jwt() ->> 'email';
  c_target   constant int := 10;       -- SESSION_TARGET in student-dashboard.js
  v_sq       public.served_questions%rowtype;
  v_answered int;
  v_topic    int;
  v_q        record;
  v_parsed   jsonb;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'student' then
    raise exception 'PIA: only students take lessons.' using errcode = '42501';
  end if;
  if p_session_id is null then
    raise exception 'PIA: a session is required.' using errcode = '22023';
  end if;

  -- One serve or record at a time per student.
  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select sq.* into v_sq
    from public.served_questions sq
   where sq.session_id = p_session_id and sq.student_email = v_email
     and not exists (select 1 from public.tutoring_attempts t
                      where t.session_id = sq.session_id and t.student_email = sq.student_email
                        and t.problem_id = sq.problem_id)
   order by sq.problem_number desc
   limit 1;

  if found then
    return public.pia_question_payload(v_sq);
  end if;

  select count(*) into v_answered
    from public.tutoring_attempts t
   where t.session_id = p_session_id and t.student_email = v_email and t.problem_id like 'qb-%';

  if v_answered >= c_target then
    return jsonb_build_object('done', true, 'reason', 'target', 'problems_answered', v_answered);
  end if;

  v_topic := public.pia_student_topic(v_email);

  select q.id, q.question, q.final_answer, q.hint,
         case upper(q.difficulty) when 'EASY' then 1 when 'MEDIUM' then 2 else 3 end as topic
    into v_q
    from public.question_bank q
   where upper(q.difficulty) in ('EASY', 'MEDIUM', 'HARD')
     and trim(coalesce(q.question, '')) <> ''
     and trim(coalesce(q.final_answer, '')) <> ''
     and not exists (select 1 from public.served_questions s
                      where s.session_id = p_session_id and s.student_email = v_email
                        and s.question_id = q.id)
   order by abs((case upper(q.difficulty) when 'EASY' then 1 when 'MEDIUM' then 2 else 3 end) - v_topic),
            (select count(*) from public.served_questions s2
              where s2.student_email = v_email and s2.question_id = q.id),
            random()
   limit 1;

  if not found then
    return jsonb_build_object('done', true, 'reason', 'bank_empty', 'problems_answered', v_answered);
  end if;

  v_parsed := public.pia_parse_hint(v_q.hint);

  insert into public.served_questions (
    session_id, student_email, problem_id, problem_number, question_id,
    topic, student_topic, question, final_answer, steps, default_hint)
  values (
    p_session_id, v_email, 'qb-' || v_q.id, v_answered + 1, v_q.id,
    v_q.topic, v_topic, v_q.question, coalesce(v_q.final_answer, ''),
    v_parsed -> 'steps', nullif(v_parsed ->> 'defaultHint', ''))
  returning * into v_sq;

  -- The serve stamp that timing (and the teacher monitor) already use.
  insert into public.problem_serves (session_id, student_email, problem_id, problem_number)
  values (p_session_id, v_email, v_sq.problem_id, v_sq.problem_number)
  on conflict (session_id, problem_id) do nothing;

  return public.pia_question_payload(v_sq);
end;
$$;


--
-- Name: serve_next_step_question(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.serve_next_step_question(p_session_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email    text;
  v_offer    public.topic_offers%rowtype;
  v_sq       public.served_questions%rowtype;
  v_st       public.step_states%rowtype;
  v_w        public.game_windows%rowtype;
  v_topic    int;
  v_q        record;
  v_parsed   jsonb;
  v_number   int;
  v_repeat   int;
  v_last_q   bigint;
begin
  v_email := public.pia_game_email();
  if p_session_id is null then
    raise exception 'PIA: a session is required.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  -- The session clock starts with the first problem and never pauses.
  v_w := public.pia_game_window(p_session_id, v_email);

  select * into v_offer from public.topic_offers
   where session_id = p_session_id and student_email = v_email and status = 'pending'
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('done', false, 'clock', public.pia_clock_json(v_w),
      'pending_offer', jsonb_build_object(
        'problem_id', v_offer.problem_id, 'type', v_offer.offer,
        'from_topic', v_offer.from_topic, 'target_topic', v_offer.target_topic));
  end if;

  select sq.* into v_sq
    from public.served_questions sq
   where sq.session_id = p_session_id and sq.student_email = v_email
     and exists (select 1 from public.step_states s
                  where s.session_id = sq.session_id and s.student_email = sq.student_email
                    and s.problem_id = sq.problem_id)
     and not exists (select 1 from public.tutoring_attempts t
                      where t.session_id = sq.session_id and t.student_email = sq.student_email
                        and t.problem_id = sq.problem_id)
   order by sq.problem_number desc
   limit 1;

  if found then
    select * into v_st from public.step_states
     where session_id = v_sq.session_id and student_email = v_email and problem_id = v_sq.problem_id;
    return public.pia_step_state_json(v_sq, v_st) || jsonb_build_object('clock', public.pia_clock_json(v_w));
  end if;

  v_topic := public.pia_student_topic(v_email);

  select coalesce(max(problem_number), 0) + 1, (array_agg(question_id order by problem_number desc))[1]
    into v_number, v_last_q
    from public.served_questions where session_id = p_session_id and student_email = v_email;

  -- The game uses every question once, shuffled, before any repeats, and never
  -- shows the same one twice in a row: fewest times seen this session first.
  select q.id, q.question, q.final_answer, q.hint,
         case upper(q.difficulty) when 'EASY' then 1 when 'MEDIUM' then 2 else 3 end as topic
    into v_q
    from public.question_bank q
   where upper(q.difficulty) in ('EASY', 'MEDIUM', 'HARD')
     and trim(coalesce(q.question, '')) <> ''
     and public.pia_steps_valid(
           public.pia_parse_hint(q.hint) -> 'steps',
           case upper(q.difficulty) when 'EASY' then 1 when 'MEDIUM' then 2 else 3 end)
   order by abs((case upper(q.difficulty) when 'EASY' then 1 when 'MEDIUM' then 2 else 3 end) - v_topic),
            (select count(*) from public.served_questions s
              where s.session_id = p_session_id and s.student_email = v_email and s.question_id = q.id),
            (q.id = v_last_q),
            (select count(*) from public.served_questions s2
              where s2.student_email = v_email and s2.question_id = q.id),
            random()
   limit 1;

  if not found then
    return jsonb_build_object('done', true, 'reason', 'bank_empty', 'clock', public.pia_clock_json(v_w));
  end if;

  select count(*) into v_repeat from public.served_questions
   where session_id = p_session_id and student_email = v_email and question_id = v_q.id;

  v_parsed := public.pia_parse_hint(v_q.hint);

  insert into public.served_questions (
    session_id, student_email, problem_id, problem_number, question_id,
    topic, student_topic, question, final_answer, steps, default_hint)
  values (
    p_session_id, v_email,
    'qb-' || v_q.id || case when v_repeat > 0 then '#' || v_repeat else '' end,
    v_number, v_q.id,
    v_q.topic, v_topic, v_q.question, coalesce(v_q.final_answer, ''),
    v_parsed -> 'steps', nullif(v_parsed ->> 'defaultHint', ''))
  returning * into v_sq;

  insert into public.step_states (session_id, student_email, problem_id)
  values (p_session_id, v_email, v_sq.problem_id)
  returning * into v_st;

  -- The serve stamp that timing (and the teacher monitor) already use.
  insert into public.problem_serves (session_id, student_email, problem_id, problem_number)
  values (p_session_id, v_email, v_sq.problem_id, v_sq.problem_number)
  on conflict (session_id, problem_id) do nothing;

  return public.pia_step_state_json(v_sq, v_st) || jsonb_build_object('clock', public.pia_clock_json(v_w));
end;
$$;


--
-- Name: serve_problem(uuid, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.serve_problem(p_session_id uuid, p_problem_id text, p_problem_number integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_state jsonb;
  v_hints int;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  if not exists (select 1 from public.math_answers where problem_id = p_problem_id) then
    raise exception 'PIA: unknown problem_id: %', p_problem_id using errcode = '22023';
  end if;

  -- Ang UNANG serve lang ang tumatatak ng oras. Ang pag-refresh ng page ay
  -- hindi nagre-reset ng orasan -- kung hindi, libre ang dagdag na oras.
  insert into public.problem_serves (session_id, student_email, problem_id, problem_number)
  values (p_session_id, v_email, p_problem_id, greatest(1, least(50, p_problem_number)))
  on conflict (session_id, problem_id) do nothing;

  select count(*) into v_hints from public.math_hints where problem_id = p_problem_id;
  v_state := public.pia_session_state(p_session_id, v_email);

  return jsonb_build_object(
    'level',               v_state ->> 'level',
    'consecutive_correct', v_state ->> 'consecutive_correct',
    'hints_available',     v_hints);
end;
$$;


--
-- Name: set_student_stage(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_student_stage(p_stage text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  v_flag    text;
  v_ok      boolean := false;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  if p_stage is null or p_stage not in ('OCEAN', 'Character Selection', 'Tutoring Dashboard', 'Waiting Room') then
    raise exception 'PIA: unknown stage: %', coalesce(p_stage, '(null)') using errcode = '22023';
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  v_flag := case p_stage
              when 'OCEAN'              then 'stage_ocean'
              when 'Character Selection' then 'stage_char'
              when 'Tutoring Dashboard' then 'stage_dash'
              else null
            end;

  if public.pia_can_enter_stage(v_profile.is_ocean_done, v_profile.group_type,
                                v_profile.selected_character, p_stage) then
    v_ok := v_flag is null
            or public.pia_stage_open(v_flag)
            or v_profile.current_stage is not distinct from p_stage;  -- targeted grant ng admin
  end if;

  if not v_ok then
    if v_profile.current_stage is distinct from 'Waiting Room' then
      update public.profiles
         set current_stage = 'Waiting Room', stage_started_at = now()
       where email = v_email;
    end if;
    return jsonb_build_object('stage', 'Waiting Room', 'granted', false);
  end if;

  if v_profile.current_stage is distinct from p_stage then
    update public.profiles
       set current_stage = p_stage, stage_started_at = now()
     where email = v_email;
  end if;

  return jsonb_build_object('stage', p_stage, 'granted', true);
end;
$$;


--
-- Name: start_game_session(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_game_session() RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$declare v_email text; v_id uuid;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

  perform public.guard_session_start();
  v_email := auth.jwt() ->> 'email';
  if v_email is null then raise exception 'authentication required'; end if;

  -- Only one active session per student.
  update public.game_sessions
     set is_active = false, ended_at = now()
   where student_email = v_email and is_active;

  insert into public.game_sessions (student_email)
  values (v_email)
  returning id into v_id;

  return v_id;
end;$$;


--
-- Name: submit_ocean_results(integer[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_ocean_results(p_responses integer[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  r         integer[];
  k         record;
  v_needs_character boolean;
  v_is_control boolean;
  v_next_stage text;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  -- Once only. The admin retake action sets is_ocean_done back to false.
  if coalesce(v_profile.is_ocean_done, false) then
    raise exception 'PIA: this questionnaire has already been submitted. Ask an admin for a retake.'
      using errcode = '42501';
  end if;

  if p_responses is null or array_length(p_responses, 1) is distinct from 50 then
    raise exception 'PIA: exactly 50 responses are required (received: %).',
      coalesce(array_length(p_responses, 1), 0) using errcode = '22023';
  end if;

  -- Re-based to 1..50 in order, so r[n] is item n even if a caller crafts an
  -- array with a different lower bound.
  r := array(select x from unnest(p_responses) with ordinality as t(x, i) order by i);

  if exists (select 1 from unnest(r) v where v is null or v < 1 or v > 5) then
    raise exception 'PIA: every response must be between 1 and 5.' using errcode = '22023';
  end if;

  select * into k from public.pia_bfpt_score(r);

  -- Next stage -- decided here, never in the browser. 0038: a Control student
  -- has no stage after OCEAN, so they are parked in the Waiting Room (always
  -- permitted); the student pages show them the thank-you screen there.
  v_is_control := lower(trim(coalesce(v_profile.group_type, ''))) = 'control';
  v_needs_character :=
    lower(trim(coalesce(v_profile.group_type, ''))) in ('non-assigned', 'non_assigned')
    and v_profile.selected_character is null;

  if v_is_control then
    v_next_stage := 'Waiting Room';
  elsif v_needs_character then
    v_next_stage := case when public.pia_stage_open('stage_char')
                         then 'Character Selection' else 'Waiting Room' end;
  else
    v_next_stage := case when public.pia_stage_open('stage_dash')
                         then 'Tutoring Dashboard' else 'Waiting Room' end;
  end if;

  insert into public.ocean_submissions
         (email, responses, ocean_e, ocean_a, ocean_c, ocean_n, ocean_o, scoring_key, source)
  values (v_email, r::smallint[], k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o,
          'bfpt-2026-07-22', 'questionnaire');

  -- The completion flag and the stage. Deliberately no score.
  update public.profiles set
    is_ocean_done    = true,
    current_stage    = v_next_stage,
    stage_started_at = now()
  where email = v_email;

  return jsonb_build_object('next_stage', v_next_stage);
end;
$$;


--
-- Name: submit_ocean_results_teacher(integer[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_ocean_results_teacher(p_responses integer[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  r         integer[];
  k         record;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' or not public.jwt_is_current() then
    raise exception 'PIA: only a teacher can use this questionnaire.' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  if coalesce(v_profile.is_ocean_done, false) then
    raise exception 'PIA: this questionnaire has already been submitted. Ask an admin for a retake.'
      using errcode = '42501';
  end if;

  if p_responses is null or array_length(p_responses, 1) is distinct from 50 then
    raise exception 'PIA: exactly 50 responses are required (received: %).',
      coalesce(array_length(p_responses, 1), 0) using errcode = '22023';
  end if;

  r := array(select x from unnest(p_responses) with ordinality as t(x, i) order by i);

  if exists (select 1 from unnest(r) v where v is null or v < 1 or v > 5) then
    raise exception 'PIA: every response must be between 1 and 5.' using errcode = '22023';
  end if;

  select * into k from public.pia_bfpt_score(r);

  insert into public.ocean_submissions
         (email, responses, ocean_e, ocean_a, ocean_c, ocean_n, ocean_o, scoring_key, source)
  values (v_email, r::smallint[], k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o,
          'bfpt-2026-07-22', 'questionnaire');

  update public.profiles set is_ocean_done = true where email = v_email;

  return jsonb_build_object('done', true);
end;
$$;


--
-- Name: teacher_class_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.teacher_class_status() RETURNS TABLE(student_key text, full_name text, activity text, problems_done integer, problems_target integer, attention text, attention_minutes integer, seconds_since_active integer, online boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email    text := lower(auth.jwt() ->> 'email');
  v_section  text;
  -- Keep in step with SESSION_TARGET in student/js/student-dashboard.js.
  c_target   constant int      := 10;
  c_online   constant interval := '2 minutes';   -- heartbeat is every 45 s
  c_idle     constant interval := '3 minutes';
  c_stuck    constant interval := '5 minutes';
  c_dropped  constant interval := '15 minutes';
  c_window   constant interval := '3 hours';     -- "this class", generously
  r          record;
  v_seen     timestamptz;
  v_session  uuid;
  v_done     int;
  v_served   timestamptz;
  v_number   int;
  v_answered boolean;
  v_last     timestamptz;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' then
    raise exception 'PIA: only a teacher can view a class.' using errcode = '42501';
  end if;

  -- The same section the teacher dashboard shows: the teacher's profile,
  -- else the faculty record the admin assigned.
  select coalesce(
           nullif(trim(p.section), ''),
           (select nullif(trim(f.assigned_section), '') from public.professors f
             where lower(f.email) = v_email limit 1))
    into v_section
    from public.profiles p
   where lower(p.email) = v_email
   limit 1;

  if v_section is null then
    return;
  end if;

  for r in
    select p.email, p.full_name, p.current_stage
      from public.profiles p
     where p.section = v_section
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
     order by p.full_name
  loop
    v_session := null; v_done := 0; v_served := null; v_number := null;
    v_answered := false; v_last := null;

    select sp.last_seen into v_seen
      from public.student_presence sp where sp.student_email = lower(r.email);

    -- This lesson: the student's most recent session in the class window.
    select ps.session_id into v_session
      from public.problem_serves ps
     where lower(ps.student_email) = lower(r.email) and ps.served_at > now() - c_window
     order by ps.served_at desc
     limit 1;

    if v_session is not null then
      select count(*) into v_done
        from public.tutoring_attempts t
       where t.session_id = v_session and lower(t.student_email) = lower(r.email);

      select ps.served_at, ps.problem_number into v_served, v_number
        from public.problem_serves ps
       where ps.session_id = v_session and lower(ps.student_email) = lower(r.email)
       order by ps.served_at desc
       limit 1;

      select exists (select 1 from public.tutoring_attempts t
                      where t.session_id = v_session and lower(t.student_email) = lower(r.email)
                        and t.problem_number = v_number)
        into v_answered;

      -- Any action counts: a new problem, an answer attempt, a hint.
      select greatest(
               v_served,
               (select max(a.attempted_at) from public.math_attempt_log a
                 where a.session_id = v_session and lower(a.student_email) = lower(r.email)),
               (select max(q.attempted_at) from public.question_attempts q
                 where q.session_id = v_session and lower(q.student_email) = lower(r.email)),
               (select max(h.consumed_at) from public.hint_consumptions h
                 where h.session_id = v_session and lower(h.student_email) = lower(r.email)))
        into v_last;
    end if;

    student_key          := md5(lower(r.email));
    full_name            := coalesce(nullif(trim(r.full_name), ''), 'Unnamed student');
    problems_done        := least(v_done, c_target);
    problems_target      := c_target;
    online               := v_seen is not null and v_seen > now() - c_online;
    seconds_since_active := case when v_last is null then null
                                 else greatest(0, extract(epoch from now() - v_last))::int end;
    attention            := null;
    attention_minutes    := null;

    if not online then
      activity := 'offline';
      if v_session is not null and v_done < c_target and v_last > now() - c_dropped then
        attention := 'dropped';
        attention_minutes := floor(extract(epoch from now() - coalesce(v_seen, v_last)) / 60)::int;
      end if;
    elsif r.current_stage in ('OCEAN', 'Character Selection') then
      activity := 'setting_up';        -- one label for both: group-blind
    elsif r.current_stage is distinct from 'Tutoring Dashboard' then
      activity := 'waiting';
    elsif v_done >= c_target then
      activity := 'finished';
    elsif v_session is null then
      activity := 'not_started';
    elsif v_last > now() - c_idle then
      activity := 'solving';
    else
      activity := 'idle';
      attention := 'idle';
      attention_minutes := floor(extract(epoch from now() - v_last) / 60)::int;
    end if;

    -- On the same problem too long -- even while trying things, since hints
    -- and attempts keep "last action" fresh.
    if online and activity in ('solving', 'idle') and v_served is not null
       and not v_answered and v_served < now() - c_stuck then
      attention := 'stuck';
      attention_minutes := floor(extract(epoch from now() - v_served) / 60)::int;
    end if;

    return next;
  end loop;
end;
$$;


--
-- Name: teacher_my_sections(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.teacher_my_sections() RETURNS TABLE(section text, in_use boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email text := lower(auth.jwt() ->> 'email');
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' then
    raise exception 'PIA: only a teacher can do this.' using errcode = '42501';
  end if;
  return query
    select ps.section,
           coalesce(ps.section = (select p.section from public.profiles p where lower(p.email) = v_email limit 1), false)
      from public.professor_sections ps
     where ps.email = v_email
     order by ps.section;
end;
$$;


--
-- Name: teacher_revoke_device(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.teacher_revoke_device(p_device_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $_$
declare
  v_email   text := lower(auth.jwt() ->> 'email');
  v_devices text[];
  v_map     jsonb;
  v_new     text[];
  v_sid     text;
  v_uid     uuid;
  v_ended   int := 0;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' then
    raise exception 'PIA: only a teacher can use this.' using errcode = '42501';
  end if;
  if p_device_id is null or length(trim(p_device_id)) = 0 then
    raise exception 'PIA: a device id is required.' using errcode = '22023';
  end if;

  select coalesce(p.active_devices, '{}'), coalesce(p.device_sessions, '{}'::jsonb)
    into v_devices, v_map
    from public.profiles p
   where lower(p.email) = v_email
     for update;

  if not found then
    raise exception 'PIA: no profile for this account.' using errcode = '22023';
  end if;

  if not (p_device_id = any(v_devices)) then
    return jsonb_build_object('devices', v_devices, 'removed', 0, 'sessions_ended', 0);
  end if;

  v_new := array(select x from unnest(v_devices) x where x is distinct from p_device_id);
  v_sid := v_map ->> p_device_id;
  v_map := v_map - p_device_id;

  select u.id into v_uid from auth.users u where lower(u.email) = v_email limit 1;

  if v_uid is not null and v_sid ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    with gone as (
      delete from auth.sessions where id = v_sid::uuid and user_id = v_uid returning 1
    )
    select count(*) into v_ended from gone;

    delete from auth.refresh_tokens where session_id = v_sid::uuid and user_id = v_uid::text;
  end if;

  update public.profiles
     set active_devices = v_new, device_sessions = v_map
   where lower(email) = v_email;

  return jsonb_build_object('devices', v_new, 'removed', 1, 'sessions_ended', v_ended);
end;
$_$;


--
-- Name: teacher_section_roster(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.teacher_section_roster() RETURNS TABLE(student_key text, full_name text, online boolean, stage text, attendance text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email   text := lower(auth.jwt() ->> 'email');
  v_section text;
  v_checkin uuid;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' then
    raise exception 'PIA: only a teacher can view a class.' using errcode = '42501';
  end if;

  -- The teacher's own section: their profile, else the faculty record the admin assigned.
  select coalesce(
           nullif(trim(p.section), ''),
           (select nullif(trim(f.assigned_section), '') from public.professors f
             where lower(f.email) = v_email limit 1))
    into v_section
    from public.profiles p
   where lower(p.email) = v_email
   limit 1;

  if v_section is null then
    return;
  end if;

  select c.id into v_checkin
    from public.checkins c
   where c.section = v_section and c.stopped_at is null and c.ends_at > now()
   order by c.started_at desc
   limit 1;

  return query
    select md5(lower(p.email)),
           coalesce(nullif(trim(p.full_name), ''), 'Unnamed student'),
           coalesce(sp.last_seen > now() - interval '2 minutes', false),
           case p.current_stage
             when 'OCEAN'               then 'setting_up'
             when 'Character Selection' then 'setting_up'
             when 'Tutoring Dashboard'  then 'tutoring'
             else 'waiting'
           end,
           case when v_checkin is null then null
                else coalesce((select case when m.present then 'present' else 'absent' end
                                 from public.attendance_marks m
                                where m.checkin_id = v_checkin and lower(m.email) = lower(p.email)),
                              'not_marked')
           end
      from public.profiles p
      left join public.student_presence sp on lower(sp.student_email) = lower(p.email)
     where p.section = v_section
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
     order by p.full_name;
end;
$$;


--
-- Name: teacher_set_section(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.teacher_set_section(p_section text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email text := lower(auth.jwt() ->> 'email');
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' then
    raise exception 'PIA: only a teacher can do this.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.professor_sections ps where ps.email = v_email and ps.section = trim(coalesce(p_section, ''))) then
    raise exception 'That is not one of your sections.' using errcode = '42501';
  end if;
  update public.profiles set section = trim(p_section)
   where lower(email) = v_email and lower(trim(coalesce(role, ''))) = 'teacher';
end;
$$;


--
-- Name: touch_presence(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.touch_presence(p_online boolean DEFAULT true) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_email text := lower(auth.jwt() ->> 'email');
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  -- Only students are monitored; a staff heartbeat is simply ignored.
  if public.pia_caller_role() is distinct from 'student' then
    return;
  end if;

  if p_online then
    insert into public.student_presence (student_email, last_seen)
    values (v_email, now())
    on conflict (student_email) do update set last_seen = excluded.last_seen;
  else
    delete from public.student_presence where student_email = v_email;
  end if;
end;
$$;


--
-- Name: tutoring_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tutoring_status() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email text := public.pia_game_email();
  t       public.tutoring_schedule%rowtype;
begin
  select s.* into t
    from public.profiles p
    join public.tutoring_schedule s on s.section = nullif(trim(p.section), '')
   where lower(p.email) = lower(v_email) limit 1;

  return jsonb_build_object(
    'closed',            public.pia_tutoring_closed_for(v_email),
    'not_open_yet',      found and t.opens_at is not null and t.opens_at > now(),
    'seconds_to_open',   case when found and t.opens_at is not null and t.opens_at > now()
                              then ceil(extract(epoch from (t.opens_at - now())))::int end,
    'seconds_to_close',  case when found and t.closes_at is not null and t.closes_at > now()
                                   and not (t.opens_at is not null and t.opens_at > now())
                              then ceil(extract(epoch from (t.closes_at - now())))::int end);
end;
$$;


--
-- Name: app_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_config (
    id integer DEFAULT 1 NOT NULL,
    easy_mastery integer DEFAULT 80 NOT NULL,
    easy_max_errors integer DEFAULT 3 NOT NULL,
    easy_min_questions integer DEFAULT 3 NOT NULL,
    medium_mastery integer DEFAULT 80 NOT NULL,
    medium_max_errors integer DEFAULT 3 NOT NULL,
    medium_min_questions integer DEFAULT 3 NOT NULL,
    hard_mastery integer DEFAULT 80 NOT NULL,
    hard_max_errors integer DEFAULT 3 NOT NULL,
    hard_min_questions integer DEFAULT 3 NOT NULL,
    max_points integer DEFAULT 10 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    time_limit integer DEFAULT 10 NOT NULL,
    game_closes_at timestamp with time zone,
    score_wrong_pct integer DEFAULT 20 NOT NULL,
    score_hint_pct integer DEFAULT 10 NOT NULL,
    score_fast_bonus_pct integer DEFAULT 20 NOT NULL,
    score_fast_seconds integer DEFAULT 30 NOT NULL,
    score_speed_bonus boolean DEFAULT true NOT NULL,
    score_min integer DEFAULT 0 NOT NULL,
    score_repeat_enabled boolean DEFAULT false NOT NULL,
    score_repeat_pct integer DEFAULT 50 NOT NULL,
    CONSTRAINT app_config_score_rules_check CHECK ((((score_wrong_pct >= 0) AND (score_wrong_pct <= 100)) AND ((score_hint_pct >= 0) AND (score_hint_pct <= 100)) AND ((score_fast_bonus_pct >= 0) AND (score_fast_bonus_pct <= 100)) AND ((score_fast_seconds >= 1) AND (score_fast_seconds <= 3600)) AND ((score_min >= 0) AND (score_min <= 500)) AND ((score_repeat_pct >= 0) AND (score_repeat_pct <= 100)))),
    CONSTRAINT app_config_time_limit_check CHECK (((time_limit >= 1) AND (time_limit <= 240)))
);


--
-- Name: attendance_marks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attendance_marks (
    checkin_id uuid NOT NULL,
    email text NOT NULL,
    present boolean NOT NULL,
    entered_at timestamp with time zone,
    refused_count integer DEFAULT 0 NOT NULL,
    marked_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: checkins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.checkins (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    section text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    stopped_at timestamp with time zone,
    started_by text
);


--
-- Name: game_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.game_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    student_email text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    ended_at timestamp with time zone,
    is_active boolean DEFAULT true NOT NULL
);

ALTER TABLE ONLY public.game_sessions FORCE ROW LEVEL SECURITY;


--
-- Name: hint_consumptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hint_consumptions (
    id bigint NOT NULL,
    session_id uuid NOT NULL,
    student_email text NOT NULL,
    problem_id text NOT NULL,
    hint_index integer NOT NULL,
    consumed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: hint_consumptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.hint_consumptions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.hint_consumptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: join_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.join_attempts (
    id bigint NOT NULL,
    key text NOT NULL,
    ok boolean NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: join_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.join_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: join_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.join_attempts_id_seq OWNED BY public.join_attempts.id;


--
-- Name: join_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.join_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    section text NOT NULL,
    secret_hash text NOT NULL,
    status text DEFAULT 'waiting'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    let_in_at timestamp with time zone,
    delivered boolean DEFAULT false NOT NULL,
    CONSTRAINT join_requests_status_check CHECK ((status = ANY (ARRAY['waiting'::text, 'let_in'::text])))
);


--
-- Name: math_answers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.math_answers (
    problem_id text NOT NULL,
    answer numeric NOT NULL
);

ALTER TABLE ONLY public.math_answers FORCE ROW LEVEL SECURITY;


--
-- Name: math_attempt_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.math_attempt_log (
    id bigint NOT NULL,
    student_email text NOT NULL,
    problem_id text NOT NULL,
    session_id uuid,
    was_correct boolean NOT NULL,
    attempted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: math_attempt_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.math_attempt_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.math_attempt_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: math_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.math_attempts (
    id bigint NOT NULL,
    session_id uuid NOT NULL,
    problem_id text NOT NULL,
    attempt_no integer NOT NULL,
    submitted numeric,
    was_correct boolean NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE ONLY public.math_attempts FORCE ROW LEVEL SECURITY;


--
-- Name: math_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.math_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: math_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.math_attempts_id_seq OWNED BY public.math_attempts.id;


--
-- Name: math_hints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.math_hints (
    problem_id text NOT NULL,
    hint_index integer NOT NULL,
    hint_text text NOT NULL,
    CONSTRAINT math_hints_hint_index_check CHECK ((hint_index >= 1))
);


--
-- Name: ocean_submissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ocean_submissions (
    id bigint NOT NULL,
    email text NOT NULL,
    responses smallint[],
    ocean_e smallint NOT NULL,
    ocean_a smallint NOT NULL,
    ocean_c smallint NOT NULL,
    ocean_n smallint NOT NULL,
    ocean_o smallint NOT NULL,
    submitted_at timestamp with time zone DEFAULT now() NOT NULL,
    scoring_key text NOT NULL,
    source text NOT NULL,
    CONSTRAINT ocean_submissions_50_items CHECK (((responses IS NULL) OR (array_length(responses, 1) = 50))),
    CONSTRAINT ocean_submissions_answers_or_legacy CHECK (((responses IS NOT NULL) OR (source = 'legacy-profile'::text))),
    CONSTRAINT ocean_submissions_ocean_a_check CHECK (((ocean_a >= 0) AND (ocean_a <= 40))),
    CONSTRAINT ocean_submissions_ocean_c_check CHECK (((ocean_c >= 0) AND (ocean_c <= 40))),
    CONSTRAINT ocean_submissions_ocean_e_check CHECK (((ocean_e >= 0) AND (ocean_e <= 40))),
    CONSTRAINT ocean_submissions_ocean_n_check CHECK (((ocean_n >= 0) AND (ocean_n <= 40))),
    CONSTRAINT ocean_submissions_ocean_o_check CHECK (((ocean_o >= 0) AND (ocean_o <= 40)))
);


--
-- Name: ocean_submissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ocean_submissions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ocean_submissions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: problem_serves; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.problem_serves (
    session_id uuid NOT NULL,
    student_email text NOT NULL,
    problem_id text NOT NULL,
    problem_number integer NOT NULL,
    served_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: professor_sections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professor_sections (
    email text NOT NULL,
    section text NOT NULL
);


--
-- Name: professors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professors (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    email text NOT NULL,
    department text,
    assigned_section text,
    status text DEFAULT 'inactive'::text,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE ONLY public.professors REPLICA IDENTITY FULL;

ALTER TABLE ONLY public.professors FORCE ROW LEVEL SECURITY;


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    full_name text NOT NULL,
    role text DEFAULT 'student'::text NOT NULL,
    section text,
    group_type text,
    pre_test_score numeric,
    post_test_score numeric,
    status text,
    email text,
    selected_character text,
    ocean_o integer,
    ocean_c integer,
    ocean_e integer,
    ocean_a integer,
    ocean_n integer,
    is_ocean_done boolean DEFAULT false,
    max_devices integer DEFAULT 1,
    active_devices text[] DEFAULT '{}'::text[],
    current_stage text,
    stage_started_at timestamp with time zone,
    sessions_revoked_at timestamp with time zone,
    is_in_game boolean DEFAULT false NOT NULL,
    current_problem integer DEFAULT 0 NOT NULL,
    current_difficulty text,
    hints_used integer DEFAULT 0 NOT NULL,
    consecutive_correct integer DEFAULT 0 NOT NULL,
    must_change_password boolean DEFAULT false NOT NULL,
    temp_password_set_at timestamp with time zone,
    temp_password_set_by text,
    active_session_id uuid,
    active_session_at timestamp with time zone,
    device_sessions jsonb DEFAULT '{}'::jsonb NOT NULL,
    parental_consent boolean,
    student_assent boolean,
    pre_test_raw_score numeric,
    pre_test_max_score numeric,
    post_test_raw_score numeric,
    post_test_max_score numeric,
    CONSTRAINT profiles_ocean_scores_admin_only CHECK (((ocean_e IS NULL) AND (ocean_a IS NULL) AND (ocean_c IS NULL) AND (ocean_n IS NULL) AND (ocean_o IS NULL))),
    CONSTRAINT profiles_post_test_raw_valid CHECK ((((post_test_raw_score IS NULL) = (post_test_max_score IS NULL)) AND ((post_test_max_score IS NULL) OR ((post_test_max_score > (0)::numeric) AND (post_test_raw_score >= (0)::numeric) AND (post_test_raw_score <= post_test_max_score))))),
    CONSTRAINT profiles_pre_test_raw_valid CHECK ((((pre_test_raw_score IS NULL) = (pre_test_max_score IS NULL)) AND ((pre_test_max_score IS NULL) OR ((pre_test_max_score > (0)::numeric) AND (pre_test_raw_score >= (0)::numeric) AND (pre_test_raw_score <= pre_test_max_score))))),
    CONSTRAINT profiles_pre_test_score_not_negative CHECK ((pre_test_score >= (0)::numeric))
);

ALTER TABLE ONLY public.profiles REPLICA IDENTITY FULL;

ALTER TABLE ONLY public.profiles FORCE ROW LEVEL SECURITY;


--
-- Name: COLUMN profiles.pre_test_score; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.pre_test_score IS 'Transmuted pre-test score = raw / max * 50 + 50, calculated by trg_compute_test_scores (0034). A value with no raw score was entered before 0034.';


--
-- Name: COLUMN profiles.post_test_score; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.post_test_score IS 'Transmuted post-test score = raw / max * 50 + 50, calculated by trg_compute_test_scores (0034). A value with no raw score was entered before 0034.';


--
-- Name: COLUMN profiles.must_change_password; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.must_change_password IS 'True after an admin sets a temporary password. Cleared only by the auth.users trigger when the password changes.';


--
-- Name: COLUMN profiles.active_session_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.active_session_id IS 'Students only: the auth session (JWT session_id) that may use this account. Written by claim_student_session(); a newer sign-in replaces it (0027).';


--
-- Name: COLUMN profiles.active_session_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.active_session_at IS 'When active_session_id was last claimed (0027).';


--
-- Name: COLUMN profiles.device_sessions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.device_sessions IS '{ device id: auth session id } for the devices in active_devices. Written by claim_device(); lets admin_revoke_device() end the session behind a device (0030).';


--
-- Name: COLUMN profiles.parental_consent; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.parental_consent IS 'Parental consent form received (0033). null = not recorded, false = not received, true = received. Admin-written.';


--
-- Name: COLUMN profiles.student_assent; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.student_assent IS 'Student assent received (0033). null = not recorded, false = not received, true = received. Admin-written.';


--
-- Name: COLUMN profiles.pre_test_raw_score; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.pre_test_raw_score IS 'Pre-test raw score as entered (0034).';


--
-- Name: COLUMN profiles.pre_test_max_score; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.pre_test_max_score IS 'Pre-test highest possible score as entered (0034).';


--
-- Name: COLUMN profiles.post_test_raw_score; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.post_test_raw_score IS 'Post-test raw score as entered (0034).';


--
-- Name: COLUMN profiles.post_test_max_score; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.post_test_max_score IS 'Post-test highest possible score as entered (0034).';


--
-- Name: question_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.question_attempts (
    id bigint NOT NULL,
    session_id uuid NOT NULL,
    student_email text NOT NULL,
    problem_id text NOT NULL,
    attempt_number integer NOT NULL,
    submitted text NOT NULL,
    was_correct boolean NOT NULL,
    attempted_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT question_attempts_attempt_number_check CHECK (((attempt_number >= 1) AND (attempt_number <= 2)))
);


--
-- Name: question_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.question_attempts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.question_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: question_bank; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.question_bank (
    id bigint NOT NULL,
    difficulty text DEFAULT 'EASY'::text NOT NULL,
    question text DEFAULT ''::text NOT NULL,
    final_answer text DEFAULT ''::text NOT NULL,
    hint text,
    points integer DEFAULT 10 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: question_bank_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.question_bank ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.question_bank_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sections (
    id bigint NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE ONLY public.sections FORCE ROW LEVEL SECURITY;


--
-- Name: sections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.sections ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.sections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: security_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.security_audit_log (
    id bigint NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL,
    actor_email text,
    actor_role text,
    action text NOT NULL,
    target_email text,
    detail jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: TABLE security_audit_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.security_audit_log IS 'Security-relevant changes to accounts (0031). Append-only: written by triggers, readable by admins.';


--
-- Name: security_audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.security_audit_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.security_audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: session_start_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.session_start_log (
    id bigint NOT NULL,
    student_email text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: session_start_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.session_start_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.session_start_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settings (
    key text NOT NULL,
    value jsonb NOT NULL
);

ALTER TABLE ONLY public.settings FORCE ROW LEVEL SECURITY;


--
-- Name: stage_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stage_overrides (
    id bigint NOT NULL,
    stage text NOT NULL,
    section text NOT NULL,
    granted_count integer DEFAULT 0 NOT NULL,
    granted_by text,
    granted_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT stage_overrides_stage_check CHECK ((stage = ANY (ARRAY['ocean'::text, 'char'::text, 'dash'::text])))
);


--
-- Name: TABLE stage_overrides; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.stage_overrides IS 'Sections opened into a closed stage by admin_grant_stage (0033). Cleared when the stage is opened or closed for everyone.';


--
-- Name: stage_overrides_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.stage_overrides ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.stage_overrides_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: step_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.step_events (
    id bigint NOT NULL,
    session_id uuid NOT NULL,
    student_email text NOT NULL,
    problem_id text NOT NULL,
    step_index integer NOT NULL,
    stage text NOT NULL,
    submitted text NOT NULL,
    outcome text NOT NULL,
    happened_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: step_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.step_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.step_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: step_hints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.step_hints (
    id bigint NOT NULL,
    session_id uuid NOT NULL,
    student_email text NOT NULL,
    problem_id text NOT NULL,
    step_index integer NOT NULL,
    tier integer NOT NULL,
    tiers_total integer NOT NULL,
    taken_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: step_hints_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.step_hints ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.step_hints_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: student_numbers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.student_numbers (
    email text NOT NULL,
    number_key text NOT NULL,
    number text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT student_numbers_number_key_check CHECK ((number_key ~ '^[0-9]{11}$'::text))
);


--
-- Name: student_presence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.student_presence (
    student_email text NOT NULL,
    last_seen timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: student_stage_time; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.student_stage_time (
    student_email text NOT NULL,
    ocean_time integer DEFAULT 0 NOT NULL,
    character_select_time integer DEFAULT 0 NOT NULL,
    tutoring_time integer DEFAULT 0 NOT NULL,
    ocean_time_locked_at timestamp with time zone,
    character_select_time_locked_at timestamp with time zone,
    tutoring_time_locked_at timestamp with time zone,
    heartbeat_stage text,
    last_heartbeat_timestamp timestamp with time zone,
    CONSTRAINT student_stage_time_character_select_time_check CHECK ((character_select_time >= 0)),
    CONSTRAINT student_stage_time_ocean_time_check CHECK ((ocean_time >= 0)),
    CONSTRAINT student_stage_time_tutoring_time_check CHECK ((tutoring_time >= 0))
);


--
-- Name: TABLE student_stage_time; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.student_stage_time IS 'Active seconds per stage, credited by record_heartbeat() from the server clock and frozen by finalize_stage_time() (0035).';


--
-- Name: student_topic_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.student_topic_progress (
    student_email text NOT NULL,
    topic integer DEFAULT 1 NOT NULL,
    stint_answered integer DEFAULT 0 NOT NULL,
    stint_correct integer DEFAULT 0 NOT NULL,
    stint_wrong integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    failed_streak integer DEFAULT 0 NOT NULL,
    CONSTRAINT student_topic_progress_topic_check CHECK (((topic >= 1) AND (topic <= 3)))
);


--
-- Name: topic_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.topic_changes (
    id bigint NOT NULL,
    student_email text NOT NULL,
    session_id uuid,
    problem_number integer,
    from_topic integer NOT NULL,
    to_topic integer NOT NULL,
    reason text NOT NULL,
    stint_answered integer NOT NULL,
    stint_correct integer NOT NULL,
    stint_wrong integer NOT NULL,
    mastery integer NOT NULL,
    min_solved integer NOT NULL,
    max_errors integer NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: topic_changes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.topic_changes ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.topic_changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: topic_offers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.topic_offers (
    session_id uuid NOT NULL,
    student_email text NOT NULL,
    problem_id text NOT NULL,
    offer text NOT NULL,
    from_topic integer NOT NULL,
    target_topic integer NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved_at timestamp with time zone,
    CONSTRAINT topic_offers_offer_check CHECK ((offer = ANY (ARRAY['up'::text, 'down'::text]))),
    CONSTRAINT topic_offers_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'refused'::text])))
);


--
-- Name: tutoring_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tutoring_attempts (
    id bigint NOT NULL,
    session_id uuid NOT NULL,
    student_email text NOT NULL,
    problem_id text NOT NULL,
    problem_number smallint NOT NULL,
    level_before smallint NOT NULL,
    level_after smallint NOT NULL,
    attempts_used smallint DEFAULT 0 NOT NULL,
    hints_used smallint DEFAULT 0 NOT NULL,
    time_taken_ms integer DEFAULT 0 NOT NULL,
    is_correct boolean NOT NULL,
    classification text NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tutoring_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tutoring_attempts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.tutoring_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tutoring_schedule; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tutoring_schedule (
    section text NOT NULL,
    opens_at timestamp with time zone,
    closes_at timestamp with time zone,
    set_by text,
    set_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tutoring_schedule_check CHECK (((opens_at IS NOT NULL) OR (closes_at IS NOT NULL))),
    CONSTRAINT tutoring_schedule_check1 CHECK (((opens_at IS NULL) OR (closes_at IS NULL) OR (closes_at > opens_at)))
);


--
-- Name: TABLE tutoring_schedule; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.tutoring_schedule IS 'When the Tutoring is open for a section (0060). No row = not limited by time. Replaces app_config.game_closes_at.';


--
-- Name: v_tutoring_session_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_tutoring_session_summary WITH (security_invoker='on') AS
 SELECT session_id,
    student_email,
    min(recorded_at) AS started_at,
    max(recorded_at) AS ended_at,
    (count(*))::integer AS problems_answered,
    (count(*) FILTER (WHERE is_correct))::integer AS correct_count,
    round(((100.0 * (count(*) FILTER (WHERE is_correct))::numeric) / (NULLIF(count(*), 0))::numeric), 1) AS accuracy_pct,
    (max(level_after))::integer AS highest_level,
    ((array_agg(level_after ORDER BY problem_number DESC))[1])::integer AS final_level,
    (sum(hints_used))::integer AS total_hints,
    (sum(attempts_used))::integer AS total_attempts,
    round((avg(time_taken_ms) / 1000.0), 1) AS avg_seconds_per_problem,
    (count(*) FILTER (WHERE (classification = 'smooth'::text)))::integer AS smooth_count,
    (count(*) FILTER (WHERE (classification = 'struggling'::text)))::integer AS struggling_count,
    (count(*) >= 10) AS completed
   FROM public.tutoring_attempts a
  GROUP BY session_id, student_email;


--
-- Name: v_student_tutoring_export; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_student_tutoring_export WITH (security_invoker='on') AS
 SELECT p.email,
    p.full_name,
    p.section,
    p.group_type,
    p.selected_character,
    p.pre_test_score,
    p.post_test_score,
    p.ocean_o,
    p.ocean_c,
    p.ocean_e,
    p.ocean_a,
    p.ocean_n,
    (count(DISTINCT s.session_id))::integer AS sessions_started,
    (count(DISTINCT s.session_id) FILTER (WHERE s.completed))::integer AS sessions_completed,
    (sum(s.problems_answered))::integer AS total_problems,
    (sum(s.correct_count))::integer AS total_correct,
    round(((100.0 * (sum(s.correct_count))::numeric) / (NULLIF(sum(s.problems_answered), 0))::numeric), 1) AS overall_accuracy_pct,
    max(s.final_level) AS best_final_level,
    (sum(s.total_hints))::integer AS total_hints,
    round(avg(s.avg_seconds_per_problem), 1) AS avg_seconds_per_problem
   FROM (public.profiles p
     LEFT JOIN public.v_tutoring_session_summary s ON ((s.student_email = p.email)))
  WHERE (COALESCE(lower(TRIM(BOTH FROM p.role)), 'student'::text) = 'student'::text)
  GROUP BY p.email, p.full_name, p.section, p.group_type, p.selected_character, p.pre_test_score, p.post_test_score, p.ocean_o, p.ocean_c, p.ocean_e, p.ocean_a, p.ocean_n;


--
-- Name: join_attempts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.join_attempts ALTER COLUMN id SET DEFAULT nextval('public.join_attempts_id_seq'::regclass);


--
-- Name: math_attempts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.math_attempts ALTER COLUMN id SET DEFAULT nextval('public.math_attempts_id_seq'::regclass);


--
-- Name: app_config app_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_config
    ADD CONSTRAINT app_config_pkey PRIMARY KEY (id);


--
-- Name: app_config app_config_ranges; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.app_config
    ADD CONSTRAINT app_config_ranges CHECK ((((easy_mastery >= 50) AND (easy_mastery <= 100)) AND ((medium_mastery >= 50) AND (medium_mastery <= 100)) AND ((hard_mastery >= 50) AND (hard_mastery <= 100)) AND ((easy_max_errors >= 1) AND (easy_max_errors <= 10)) AND ((medium_max_errors >= 1) AND (medium_max_errors <= 10)) AND ((hard_max_errors >= 1) AND (hard_max_errors <= 10)) AND ((easy_min_questions >= 1) AND (easy_min_questions <= 10)) AND ((medium_min_questions >= 1) AND (medium_min_questions <= 10)) AND ((hard_min_questions >= 1) AND (hard_min_questions <= 10)) AND ((max_points >= 1) AND (max_points <= 500)))) NOT VALID;


--
-- Name: app_config app_config_single_row; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.app_config
    ADD CONSTRAINT app_config_single_row CHECK ((id = 1)) NOT VALID;


--
-- Name: attendance_marks attendance_marks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance_marks
    ADD CONSTRAINT attendance_marks_pkey PRIMARY KEY (checkin_id, email);


--
-- Name: checkins checkins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.checkins
    ADD CONSTRAINT checkins_pkey PRIMARY KEY (id);


--
-- Name: game_sessions game_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.game_sessions
    ADD CONSTRAINT game_sessions_pkey PRIMARY KEY (id);


--
-- Name: game_windows game_windows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.game_windows
    ADD CONSTRAINT game_windows_pkey PRIMARY KEY (session_id, student_email, window_no);


--
-- Name: hint_consumptions hint_consumptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hint_consumptions
    ADD CONSTRAINT hint_consumptions_pkey PRIMARY KEY (id);


--
-- Name: hint_consumptions hint_consumptions_session_id_student_email_problem_id_hint__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hint_consumptions
    ADD CONSTRAINT hint_consumptions_session_id_student_email_problem_id_hint__key UNIQUE (session_id, student_email, problem_id, hint_index);


--
-- Name: join_attempts join_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.join_attempts
    ADD CONSTRAINT join_attempts_pkey PRIMARY KEY (id);


--
-- Name: join_requests join_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.join_requests
    ADD CONSTRAINT join_requests_pkey PRIMARY KEY (id);


--
-- Name: math_answers math_answers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.math_answers
    ADD CONSTRAINT math_answers_pkey PRIMARY KEY (problem_id);


--
-- Name: math_attempt_log math_attempt_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.math_attempt_log
    ADD CONSTRAINT math_attempt_log_pkey PRIMARY KEY (id);


--
-- Name: math_attempts math_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.math_attempts
    ADD CONSTRAINT math_attempts_pkey PRIMARY KEY (id);


--
-- Name: math_hints math_hints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.math_hints
    ADD CONSTRAINT math_hints_pkey PRIMARY KEY (problem_id, hint_index);


--
-- Name: ocean_submissions ocean_submissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ocean_submissions
    ADD CONSTRAINT ocean_submissions_pkey PRIMARY KEY (id);


--
-- Name: problem_serves problem_serves_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.problem_serves
    ADD CONSTRAINT problem_serves_pkey PRIMARY KEY (session_id, problem_id);


--
-- Name: professor_sections professor_sections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professor_sections
    ADD CONSTRAINT professor_sections_pkey PRIMARY KEY (email, section);


--
-- Name: professor_sections professor_sections_section_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professor_sections
    ADD CONSTRAINT professor_sections_section_key UNIQUE (section);


--
-- Name: professors professors_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professors
    ADD CONSTRAINT professors_email_key UNIQUE (email);


--
-- Name: professors professors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professors
    ADD CONSTRAINT professors_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_email_key UNIQUE (email);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: question_attempts question_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_attempts
    ADD CONSTRAINT question_attempts_pkey PRIMARY KEY (id);


--
-- Name: question_attempts question_attempts_session_id_student_email_problem_id_attem_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_attempts
    ADD CONSTRAINT question_attempts_session_id_student_email_problem_id_attem_key UNIQUE (session_id, student_email, problem_id, attempt_number);


--
-- Name: question_bank question_bank_difficulty_check; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.question_bank
    ADD CONSTRAINT question_bank_difficulty_check CHECK ((difficulty = ANY (ARRAY['EASY'::text, 'MEDIUM'::text, 'HARD'::text]))) NOT VALID;


--
-- Name: question_bank question_bank_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_bank
    ADD CONSTRAINT question_bank_pkey PRIMARY KEY (id);


--
-- Name: question_bank question_bank_points_check; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.question_bank
    ADD CONSTRAINT question_bank_points_check CHECK (((points >= 1) AND (points <= 500))) NOT VALID;


--
-- Name: question_bank question_bank_text_len_check; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.question_bank
    ADD CONSTRAINT question_bank_text_len_check CHECK (((length(question) <= 2000) AND (length(final_answer) <= 200) AND (length(COALESCE(hint, ''::text)) <= 20000))) NOT VALID;


--
-- Name: sections sections_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sections
    ADD CONSTRAINT sections_name_key UNIQUE (name);


--
-- Name: sections sections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sections
    ADD CONSTRAINT sections_pkey PRIMARY KEY (id);


--
-- Name: security_audit_log security_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.security_audit_log
    ADD CONSTRAINT security_audit_log_pkey PRIMARY KEY (id);


--
-- Name: served_questions served_questions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.served_questions
    ADD CONSTRAINT served_questions_pkey PRIMARY KEY (session_id, problem_id);


--
-- Name: session_start_log session_start_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.session_start_log
    ADD CONSTRAINT session_start_log_pkey PRIMARY KEY (id);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (key);


--
-- Name: stage_overrides stage_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_overrides
    ADD CONSTRAINT stage_overrides_pkey PRIMARY KEY (id);


--
-- Name: stage_overrides stage_overrides_stage_section_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stage_overrides
    ADD CONSTRAINT stage_overrides_stage_section_key UNIQUE (stage, section);


--
-- Name: step_events step_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.step_events
    ADD CONSTRAINT step_events_pkey PRIMARY KEY (id);


--
-- Name: step_hints step_hints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.step_hints
    ADD CONSTRAINT step_hints_pkey PRIMARY KEY (id);


--
-- Name: step_states step_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.step_states
    ADD CONSTRAINT step_states_pkey PRIMARY KEY (session_id, student_email, problem_id);


--
-- Name: student_numbers student_numbers_number_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_numbers
    ADD CONSTRAINT student_numbers_number_key_key UNIQUE (number_key);


--
-- Name: student_numbers student_numbers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_numbers
    ADD CONSTRAINT student_numbers_pkey PRIMARY KEY (email);


--
-- Name: student_presence student_presence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_presence
    ADD CONSTRAINT student_presence_pkey PRIMARY KEY (student_email);


--
-- Name: student_stage_time student_stage_time_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_stage_time
    ADD CONSTRAINT student_stage_time_pkey PRIMARY KEY (student_email);


--
-- Name: student_topic_progress student_topic_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_topic_progress
    ADD CONSTRAINT student_topic_progress_pkey PRIMARY KEY (student_email);


--
-- Name: topic_changes topic_changes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topic_changes
    ADD CONSTRAINT topic_changes_pkey PRIMARY KEY (id);


--
-- Name: topic_offers topic_offers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topic_offers
    ADD CONSTRAINT topic_offers_pkey PRIMARY KEY (session_id, student_email, problem_id);


--
-- Name: tutoring_attempts tutoring_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tutoring_attempts
    ADD CONSTRAINT tutoring_attempts_pkey PRIMARY KEY (id);


--
-- Name: tutoring_attempts tutoring_attempts_session_id_problem_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tutoring_attempts
    ADD CONSTRAINT tutoring_attempts_session_id_problem_number_key UNIQUE (session_id, problem_number);


--
-- Name: tutoring_schedule tutoring_schedule_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tutoring_schedule
    ADD CONSTRAINT tutoring_schedule_pkey PRIMARY KEY (section);


--
-- Name: checkins_one_open_per_section; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX checkins_one_open_per_section ON public.checkins USING btree (section) WHERE (stopped_at IS NULL);


--
-- Name: game_sessions_student_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX game_sessions_student_active_idx ON public.game_sessions USING btree (student_email, is_active);


--
-- Name: hint_consumptions_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hint_consumptions_lookup_idx ON public.hint_consumptions USING btree (student_email, session_id, problem_id);


--
-- Name: join_attempts_key_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX join_attempts_key_at_idx ON public.join_attempts USING btree (key, at DESC);


--
-- Name: join_requests_waiting_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX join_requests_waiting_idx ON public.join_requests USING btree (status, created_at DESC);


--
-- Name: math_attempt_log_session_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX math_attempt_log_session_idx ON public.math_attempt_log USING btree (student_email, session_id, problem_id);


--
-- Name: math_attempt_log_user_problem_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX math_attempt_log_user_problem_idx ON public.math_attempt_log USING btree (student_email, problem_id, attempted_at DESC);


--
-- Name: math_attempt_log_user_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX math_attempt_log_user_time_idx ON public.math_attempt_log USING btree (student_email, attempted_at DESC);


--
-- Name: math_attempts_unique_try; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX math_attempts_unique_try ON public.math_attempts USING btree (session_id, problem_id, attempt_no);


--
-- Name: ocean_submissions_email_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ocean_submissions_email_idx ON public.ocean_submissions USING btree (email);


--
-- Name: profiles_email_lower_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX profiles_email_lower_uidx ON public.profiles USING btree (lower(email));


--
-- Name: question_bank_difficulty_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX question_bank_difficulty_idx ON public.question_bank USING btree (difficulty, id);


--
-- Name: security_audit_log_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX security_audit_log_at_idx ON public.security_audit_log USING btree (at DESC);


--
-- Name: served_questions_student_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX served_questions_student_idx ON public.served_questions USING btree (student_email, question_id);


--
-- Name: session_start_log_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX session_start_log_idx ON public.session_start_log USING btree (student_email, started_at DESC);


--
-- Name: step_events_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX step_events_lookup_idx ON public.step_events USING btree (session_id, student_email, problem_id);


--
-- Name: step_hints_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX step_hints_lookup_idx ON public.step_hints USING btree (session_id, student_email, problem_id);


--
-- Name: topic_changes_student_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX topic_changes_student_idx ON public.topic_changes USING btree (student_email, changed_at);


--
-- Name: tutoring_attempts_session_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tutoring_attempts_session_idx ON public.tutoring_attempts USING btree (session_id);


--
-- Name: tutoring_attempts_student_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tutoring_attempts_student_idx ON public.tutoring_attempts USING btree (student_email, recorded_at DESC);


--
-- Name: app_config app_config_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER app_config_touch BEFORE UPDATE ON public.app_config FOR EACH ROW EXECUTE FUNCTION public.pia_touch_updated_at();


--
-- Name: ocean_submissions ocean_submission_assign_tutor; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ocean_submission_assign_tutor AFTER INSERT ON public.ocean_submissions FOR EACH ROW EXECUTE FUNCTION public.pia_assign_tutor_from_ocean();


--
-- Name: profiles on_profile_created_auth; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER on_profile_created_auth AFTER INSERT ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.handle_new_student_auth();


--
-- Name: professors professors_claim_section; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER professors_claim_section BEFORE INSERT OR UPDATE OF assigned_section ON public.professors FOR EACH ROW EXECUTE FUNCTION public.professors_claim_section();


--
-- Name: profiles profiles_guard_tutor_choice; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER profiles_guard_tutor_choice BEFORE UPDATE OF selected_character ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.pia_guard_tutor_choice();


--
-- Name: profiles profiles_neutral_tutor; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER profiles_neutral_tutor BEFORE INSERT OR UPDATE OF group_type, selected_character ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.pia_neutral_tutor();


--
-- Name: question_bank question_bank_touch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER question_bank_touch BEFORE UPDATE ON public.question_bank FOR EACH ROW EXECUTE FUNCTION public.pia_touch_updated_at();


--
-- Name: served_questions served_questions_base_points; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER served_questions_base_points BEFORE INSERT ON public.served_questions FOR EACH ROW EXECUTE FUNCTION public.pia_stamp_base_points();


--
-- Name: profiles trg_admin_boundaries; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_admin_boundaries BEFORE INSERT OR DELETE OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.pia_admin_boundaries();


--
-- Name: profiles trg_audit_profiles; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_profiles AFTER INSERT OR DELETE OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.pia_audit_profiles();


--
-- Name: settings trg_clear_stage_overrides; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_clear_stage_overrides AFTER INSERT OR UPDATE ON public.settings FOR EACH ROW EXECUTE FUNCTION public.pia_clear_stage_overrides();


--
-- Name: profiles trg_compute_test_scores; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_compute_test_scores BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.pia_compute_test_scores();


--
-- Name: profiles trg_enforce_profile_write_scope; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_enforce_profile_write_scope BEFORE INSERT OR DELETE OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.enforce_profile_write_scope();


--
-- Name: profiles trg_pia_control_stage_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pia_control_stage_guard BEFORE INSERT OR UPDATE OF current_stage, is_in_game, group_type ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.pia_control_stage_guard();


--
-- Name: profiles trg_pia_forget_deleted_student; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pia_forget_deleted_student AFTER DELETE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.pia_forget_deleted_student();


--
-- Name: profiles trg_pia_registration_rules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_pia_registration_rules BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.pia_registration_rules();


--
-- Name: math_attempts math_attempts_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.math_attempts
    ADD CONSTRAINT math_attempts_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.game_sessions(id) ON DELETE CASCADE;


--
-- Name: student_stage_time student_stage_time_student_email_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.student_stage_time
    ADD CONSTRAINT student_stage_time_student_email_fkey FOREIGN KEY (student_email) REFERENCES public.profiles(email) ON DELETE CASCADE;


--
-- Name: app_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

--
-- Name: app_config app_config_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY app_config_admin_all ON public.app_config TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current())) WITH CHECK (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: math_attempt_log attempt_log_select_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY attempt_log_select_admin ON public.math_attempt_log FOR SELECT TO authenticated USING (((public.current_user_role() = 'admin'::text) AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: math_attempts attempts_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY attempts_admin_read ON public.math_attempts FOR SELECT TO authenticated USING ((public.is_admin() AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: tutoring_attempts attempts_select_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY attempts_select_admin ON public.tutoring_attempts FOR SELECT TO authenticated USING (((public.current_user_role() = 'admin'::text) AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: tutoring_attempts attempts_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY attempts_select_own ON public.tutoring_attempts FOR SELECT TO authenticated USING (((student_email = (auth.jwt() ->> 'email'::text)) AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: attendance_marks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.attendance_marks ENABLE ROW LEVEL SECURITY;

--
-- Name: checkins; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.checkins ENABLE ROW LEVEL SECURITY;

--
-- Name: game_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.game_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: game_windows; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.game_windows ENABLE ROW LEVEL SECURITY;

--
-- Name: game_windows game_windows_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY game_windows_admin_read ON public.game_windows FOR SELECT TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: hint_consumptions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hint_consumptions ENABLE ROW LEVEL SECURITY;

--
-- Name: join_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.join_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: join_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.join_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: math_answers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.math_answers ENABLE ROW LEVEL SECURITY;

--
-- Name: math_attempt_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.math_attempt_log ENABLE ROW LEVEL SECURITY;

--
-- Name: math_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.math_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: math_hints; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.math_hints ENABLE ROW LEVEL SECURITY;

--
-- Name: ocean_submissions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ocean_submissions ENABLE ROW LEVEL SECURITY;

--
-- Name: ocean_submissions ocean_submissions_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ocean_submissions_admin_read ON public.ocean_submissions FOR SELECT TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: problem_serves; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.problem_serves ENABLE ROW LEVEL SECURITY;

--
-- Name: professor_sections; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.professor_sections ENABLE ROW LEVEL SECURITY;

--
-- Name: professors; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.professors ENABLE ROW LEVEL SECURITY;

--
-- Name: professors professors_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY professors_admin_all ON public.professors TO authenticated USING ((public.is_admin() AND ( SELECT public.jwt_is_current() AS jwt_is_current))) WITH CHECK ((public.is_admin() AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: professors professors_select_self; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY professors_select_self ON public.professors FOR SELECT TO authenticated USING (((email = public.current_email()) AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_admin_all ON public.profiles TO authenticated USING ((public.is_admin() AND ( SELECT public.jwt_is_current() AS jwt_is_current))) WITH CHECK ((public.is_admin() AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: profiles profiles_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_select_own ON public.profiles FOR SELECT TO authenticated USING (((email = (auth.jwt() ->> 'email'::text)) AND public.jwt_is_current()));


--
-- Name: profiles profiles_update_self; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_update_self ON public.profiles FOR UPDATE TO authenticated USING (((email = public.current_email()) AND ( SELECT public.jwt_is_current() AS jwt_is_current))) WITH CHECK (((email = public.current_email()) AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: question_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.question_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: question_bank; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.question_bank ENABLE ROW LEVEL SECURITY;

--
-- Name: question_bank question_bank_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY question_bank_admin_all ON public.question_bank TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current())) WITH CHECK (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: sections; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sections ENABLE ROW LEVEL SECURITY;

--
-- Name: sections sections_admin_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sections_admin_write ON public.sections TO authenticated USING ((public.is_admin() AND ( SELECT public.jwt_is_current() AS jwt_is_current))) WITH CHECK ((public.is_admin() AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: sections sections_read_auth; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sections_read_auth ON public.sections FOR SELECT TO authenticated USING ((true AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: security_audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.security_audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: security_audit_log security_audit_log_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY security_audit_log_admin_read ON public.security_audit_log FOR SELECT TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: served_questions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.served_questions ENABLE ROW LEVEL SECURITY;

--
-- Name: session_start_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.session_start_log ENABLE ROW LEVEL SECURITY;

--
-- Name: game_sessions sessions_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sessions_admin_read ON public.game_sessions FOR SELECT TO authenticated USING ((public.is_admin() AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;

--
-- Name: settings settings_admin_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY settings_admin_write ON public.settings TO authenticated USING ((public.is_admin() AND ( SELECT public.jwt_is_current() AS jwt_is_current))) WITH CHECK ((public.is_admin() AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: settings settings_non_admin_stage_only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY settings_non_admin_stage_only ON public.settings AS RESTRICTIVE FOR SELECT TO authenticated USING (((key ~~ 'stage\_%'::text) OR (public.pia_caller_role() = 'admin'::text)));


--
-- Name: settings settings_read_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY settings_read_all ON public.settings FOR SELECT TO authenticated USING ((true AND ( SELECT public.jwt_is_current() AS jwt_is_current)));


--
-- Name: stage_overrides; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.stage_overrides ENABLE ROW LEVEL SECURITY;

--
-- Name: stage_overrides stage_overrides_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stage_overrides_admin_read ON public.stage_overrides FOR SELECT TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: step_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.step_events ENABLE ROW LEVEL SECURITY;

--
-- Name: step_events step_events_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY step_events_admin_read ON public.step_events FOR SELECT TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: step_hints; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.step_hints ENABLE ROW LEVEL SECURITY;

--
-- Name: step_hints step_hints_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY step_hints_admin_read ON public.step_hints FOR SELECT TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: step_states; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.step_states ENABLE ROW LEVEL SECURITY;

--
-- Name: student_numbers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.student_numbers ENABLE ROW LEVEL SECURITY;

--
-- Name: student_presence; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.student_presence ENABLE ROW LEVEL SECURITY;

--
-- Name: student_stage_time; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.student_stage_time ENABLE ROW LEVEL SECURITY;

--
-- Name: student_stage_time student_stage_time_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY student_stage_time_admin_read ON public.student_stage_time FOR SELECT TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: student_topic_progress; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.student_topic_progress ENABLE ROW LEVEL SECURITY;

--
-- Name: student_topic_progress student_topic_progress_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY student_topic_progress_admin_read ON public.student_topic_progress FOR SELECT TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: topic_changes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.topic_changes ENABLE ROW LEVEL SECURITY;

--
-- Name: topic_changes topic_changes_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY topic_changes_admin_read ON public.topic_changes FOR SELECT TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: topic_offers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.topic_offers ENABLE ROW LEVEL SECURITY;

--
-- Name: topic_offers topic_offers_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY topic_offers_admin_read ON public.topic_offers FOR SELECT TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: tutoring_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tutoring_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: tutoring_schedule; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tutoring_schedule ENABLE ROW LEVEL SECURITY;

--
-- Name: tutoring_schedule tutoring_schedule_admin_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tutoring_schedule_admin_read ON public.tutoring_schedule FOR SELECT TO authenticated USING (((public.pia_caller_role() = 'admin'::text) AND public.jwt_is_current()));


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION admin_attendance(p_section text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_attendance(p_section text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_attendance(p_section text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_attendance(p_section text) TO service_role;


--
-- Name: FUNCTION admin_checkin_overview(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_checkin_overview() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_checkin_overview() TO authenticated;
GRANT ALL ON FUNCTION public.admin_checkin_overview() TO service_role;


--
-- Name: FUNCTION admin_create_auth_user(target_email text, default_password text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_create_auth_user(target_email text, default_password text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_create_auth_user(target_email text, default_password text) TO service_role;


--
-- Name: FUNCTION admin_create_auth_user__inner(target_email text, default_password text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_create_auth_user__inner(target_email text, default_password text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_create_auth_user__inner(target_email text, default_password text) TO service_role;


--
-- Name: FUNCTION admin_delete_section(p_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_delete_section(p_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_delete_section(p_name text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_delete_section(p_name text) TO service_role;


--
-- Name: FUNCTION admin_delete_user(target_email text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_delete_user(target_email text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_delete_user(target_email text) TO service_role;


--
-- Name: FUNCTION admin_delete_user__inner(target_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_delete_user__inner(target_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_delete_user__inner(target_email text) TO service_role;


--
-- Name: FUNCTION admin_grant_stage(p_stage text, p_emails text[], p_section text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_grant_stage(p_stage text, p_emails text[], p_section text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_grant_stage(p_stage text, p_emails text[], p_section text) TO service_role;


--
-- Name: FUNCTION admin_grant_stage__inner(p_stage text, p_emails text[], p_section text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_grant_stage__inner(p_stage text, p_emails text[], p_section text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_grant_stage__inner(p_stage text, p_emails text[], p_section text) TO service_role;


--
-- Name: FUNCTION admin_import_student_numbers(p_rows jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_import_student_numbers(p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_import_student_numbers(p_rows jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.admin_import_student_numbers(p_rows jsonb) TO service_role;


--
-- Name: FUNCTION admin_let_back_in(p_section text, p_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_let_back_in(p_section text, p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_let_back_in(p_section text, p_email text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_let_back_in(p_section text, p_email text) TO service_role;


--
-- Name: FUNCTION admin_let_in(p_ids uuid[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_let_in(p_ids uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_let_in(p_ids uuid[]) TO authenticated;
GRANT ALL ON FUNCTION public.admin_let_in(p_ids uuid[]) TO service_role;


--
-- Name: FUNCTION admin_numbers_for(p_emails text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_numbers_for(p_emails text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_numbers_for(p_emails text[]) TO authenticated;
GRANT ALL ON FUNCTION public.admin_numbers_for(p_emails text[]) TO service_role;


--
-- Name: FUNCTION admin_numbers_taken(p_numbers text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_numbers_taken(p_numbers text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_numbers_taken(p_numbers text[]) TO authenticated;
GRANT ALL ON FUNCTION public.admin_numbers_taken(p_numbers text[]) TO service_role;


--
-- Name: FUNCTION admin_professor_sections(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_professor_sections() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_professor_sections() TO authenticated;
GRANT ALL ON FUNCTION public.admin_professor_sections() TO service_role;


--
-- Name: FUNCTION admin_register_teacher(p_email text, p_name text, p_department text, p_assigned_section text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_register_teacher(p_email text, p_name text, p_department text, p_assigned_section text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_register_teacher(p_email text, p_name text, p_department text, p_assigned_section text) TO service_role;


--
-- Name: FUNCTION admin_register_teacher__inner(p_email text, p_name text, p_department text, p_assigned_section text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_register_teacher__inner(p_email text, p_name text, p_department text, p_assigned_section text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_register_teacher__inner(p_email text, p_name text, p_department text, p_assigned_section text) TO service_role;


--
-- Name: FUNCTION admin_rename_section(p_old text, p_new text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_rename_section(p_old text, p_new text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_rename_section(p_old text, p_new text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_rename_section(p_old text, p_new text) TO service_role;


--
-- Name: FUNCTION admin_reset_password(target_email text, new_password text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_reset_password(target_email text, new_password text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_reset_password(target_email text, new_password text) TO service_role;


--
-- Name: FUNCTION admin_reset_password__inner(target_email text, new_password text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_reset_password__inner(target_email text, new_password text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_reset_password__inner(target_email text, new_password text) TO service_role;


--
-- Name: FUNCTION admin_revoke_device(p_email text, p_device_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_revoke_device(p_email text, p_device_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_revoke_device(p_email text, p_device_id text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_revoke_device(p_email text, p_device_id text) TO service_role;


--
-- Name: FUNCTION admin_revoke_sessions(p_email text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.admin_revoke_sessions(p_email text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_revoke_sessions(p_email text) TO service_role;


--
-- Name: FUNCTION admin_revoke_sessions__inner(p_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_revoke_sessions__inner(p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_revoke_sessions__inner(p_email text) TO service_role;


--
-- Name: FUNCTION admin_revoke_stage(p_stage text, p_sections text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_revoke_stage(p_stage text, p_sections text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_revoke_stage(p_stage text, p_sections text[]) TO authenticated;
GRANT ALL ON FUNCTION public.admin_revoke_stage(p_stage text, p_sections text[]) TO service_role;


--
-- Name: FUNCTION admin_section_students(p_section text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_section_students(p_section text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_section_students(p_section text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_section_students(p_section text) TO service_role;


--
-- Name: FUNCTION admin_set_attendance(p_section text, p_email text, p_present boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_attendance(p_section text, p_email text, p_present boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_attendance(p_section text, p_email text, p_present boolean) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_attendance(p_section text, p_email text, p_present boolean) TO service_role;


--
-- Name: FUNCTION admin_set_section_professor(p_section text, p_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_section_professor(p_section text, p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_section_professor(p_section text, p_email text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_section_professor(p_section text, p_email text) TO service_role;


--
-- Name: FUNCTION admin_set_stage_open(p_stage text, p_open boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_stage_open(p_stage text, p_open boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_stage_open(p_stage text, p_open boolean) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_stage_open(p_stage text, p_open boolean) TO service_role;


--
-- Name: FUNCTION admin_set_student_number(p_email text, p_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_student_number(p_email text, p_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_student_number(p_email text, p_number text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_student_number(p_email text, p_number text) TO service_role;


--
-- Name: FUNCTION admin_set_tutoring_schedule(p_section text, p_opens timestamp with time zone, p_closes timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_set_tutoring_schedule(p_section text, p_opens timestamp with time zone, p_closes timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_set_tutoring_schedule(p_section text, p_opens timestamp with time zone, p_closes timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.admin_set_tutoring_schedule(p_section text, p_opens timestamp with time zone, p_closes timestamp with time zone) TO service_role;


--
-- Name: FUNCTION admin_start_checkin(p_section text, p_minutes integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_start_checkin(p_section text, p_minutes integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_start_checkin(p_section text, p_minutes integer) TO authenticated;
GRANT ALL ON FUNCTION public.admin_start_checkin(p_section text, p_minutes integer) TO service_role;


--
-- Name: FUNCTION admin_stop_checkin(p_section text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_stop_checkin(p_section text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_stop_checkin(p_section text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_stop_checkin(p_section text) TO service_role;


--
-- Name: FUNCTION admin_students_with_numbers(p_section text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_students_with_numbers(p_section text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_students_with_numbers(p_section text) TO authenticated;
GRANT ALL ON FUNCTION public.admin_students_with_numbers(p_section text) TO service_role;


--
-- Name: FUNCTION check_math_answer(p_session_id uuid, p_problem_id text, p_submitted numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_math_answer(p_session_id uuid, p_problem_id text, p_submitted numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_math_answer(p_session_id uuid, p_problem_id text, p_submitted numeric) TO service_role;


--
-- Name: FUNCTION check_question_answer(p_session_id uuid, p_problem_id text, p_submitted text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_question_answer(p_session_id uuid, p_problem_id text, p_submitted text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_question_answer(p_session_id uuid, p_problem_id text, p_submitted text) TO authenticated;
GRANT ALL ON FUNCTION public.check_question_answer(p_session_id uuid, p_problem_id text, p_submitted text) TO service_role;


--
-- Name: FUNCTION check_step_answer(p_session_id uuid, p_problem_id text, p_submitted text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_step_answer(p_session_id uuid, p_problem_id text, p_submitted text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_step_answer(p_session_id uuid, p_problem_id text, p_submitted text) TO authenticated;
GRANT ALL ON FUNCTION public.check_step_answer(p_session_id uuid, p_problem_id text, p_submitted text) TO service_role;


--
-- Name: FUNCTION check_student_session(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_student_session() FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_student_session() TO authenticated;
GRANT ALL ON FUNCTION public.check_student_session() TO service_role;


--
-- Name: FUNCTION claim_device(p_device_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_device(p_device_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_device(p_device_id text) TO authenticated;
GRANT ALL ON FUNCTION public.claim_device(p_device_id text) TO service_role;


--
-- Name: FUNCTION claim_student_session(p_device_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_student_session(p_device_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_student_session(p_device_id text) TO authenticated;
GRANT ALL ON FUNCTION public.claim_student_session(p_device_id text) TO service_role;


--
-- Name: FUNCTION consume_hint(p_session_id uuid, p_problem_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.consume_hint(p_session_id uuid, p_problem_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.consume_hint(p_session_id uuid, p_problem_id text) TO service_role;


--
-- Name: FUNCTION consume_question_hint(p_session_id uuid, p_problem_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.consume_question_hint(p_session_id uuid, p_problem_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.consume_question_hint(p_session_id uuid, p_problem_id text) TO authenticated;
GRANT ALL ON FUNCTION public.consume_question_hint(p_session_id uuid, p_problem_id text) TO service_role;


--
-- Name: FUNCTION consume_step_hint(p_session_id uuid, p_problem_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.consume_step_hint(p_session_id uuid, p_problem_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.consume_step_hint(p_session_id uuid, p_problem_id text) TO authenticated;
GRANT ALL ON FUNCTION public.consume_step_hint(p_session_id uuid, p_problem_id text) TO service_role;


--
-- Name: FUNCTION current_email(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.current_email() TO service_role;


--
-- Name: FUNCTION current_role_name(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.current_role_name() TO service_role;


--
-- Name: FUNCTION current_user_role(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.current_user_role() TO authenticated;
GRANT ALL ON FUNCTION public.current_user_role() TO service_role;


--
-- Name: FUNCTION current_user_section(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.current_user_section() TO authenticated;
GRANT ALL ON FUNCTION public.current_user_section() TO service_role;


--
-- Name: FUNCTION end_game_session(p_session_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.end_game_session(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.end_game_session(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.end_game_session(p_session_id uuid) TO service_role;


--
-- Name: FUNCTION enforce_device_limit(p_device_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_device_limit(p_device_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.enforce_device_limit(p_device_id text) TO service_role;


--
-- Name: FUNCTION enforce_profile_write_scope(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.enforce_profile_write_scope() TO authenticated;
GRANT ALL ON FUNCTION public.enforce_profile_write_scope() TO service_role;


--
-- Name: FUNCTION finalize_stage_time(p_stage text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_stage_time(p_stage text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_stage_time(p_stage text) TO authenticated;
GRANT ALL ON FUNCTION public.finalize_stage_time(p_stage text) TO service_role;


--
-- Name: FUNCTION finish_step_question(p_session_id uuid, p_problem_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finish_step_question(p_session_id uuid, p_problem_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finish_step_question(p_session_id uuid, p_problem_id text) TO authenticated;
GRANT ALL ON FUNCTION public.finish_step_question(p_session_id uuid, p_problem_id text) TO service_role;


--
-- Name: FUNCTION get_learning_features(p_session_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_learning_features(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_learning_features(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_learning_features(p_session_id uuid) TO service_role;


--
-- Name: FUNCTION get_session_history(p_session_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_session_history(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_session_history(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_session_history(p_session_id uuid) TO service_role;


--
-- Name: FUNCTION guard_session_start(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_session_start() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_session_start() TO authenticated;
GRANT ALL ON FUNCTION public.guard_session_start() TO service_role;


--
-- Name: FUNCTION handle_new_student_auth(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.handle_new_student_auth() TO authenticated;
GRANT ALL ON FUNCTION public.handle_new_student_auth() TO service_role;


--
-- Name: FUNCTION is_admin(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_admin() TO authenticated;
GRANT ALL ON FUNCTION public.is_admin() TO service_role;


--
-- Name: FUNCTION is_teacher(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_teacher() TO authenticated;
GRANT ALL ON FUNCTION public.is_teacher() TO service_role;


--
-- Name: FUNCTION jwt_is_current(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.jwt_is_current() TO authenticated;
GRANT ALL ON FUNCTION public.jwt_is_current() TO service_role;


--
-- Name: FUNCTION pia_admin_boundaries(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_admin_boundaries() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_admin_boundaries() TO service_role;


--
-- Name: FUNCTION pia_admin_tutorial_report(p_student_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_admin_tutorial_report(p_student_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_admin_tutorial_report(p_student_email text) TO authenticated;
GRANT ALL ON FUNCTION public.pia_admin_tutorial_report(p_student_email text) TO service_role;


--
-- Name: FUNCTION pia_answer_matches(p_submitted text, p_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_answer_matches(p_submitted text, p_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_answer_matches(p_submitted text, p_key text) TO service_role;


--
-- Name: FUNCTION pia_assign_tutor_from_ocean(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_assign_tutor_from_ocean() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_assign_tutor_from_ocean() TO service_role;


--
-- Name: FUNCTION pia_audit_profiles(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_audit_profiles() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_audit_profiles() TO service_role;


--
-- Name: FUNCTION pia_auth_user_id(p_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_auth_user_id(p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_auth_user_id(p_email text) TO service_role;


--
-- Name: FUNCTION pia_bfpt_score(r integer[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_bfpt_score(r integer[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_bfpt_score(r integer[]) TO service_role;


--
-- Name: FUNCTION pia_caller_role(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_caller_role() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_caller_role() TO authenticated;
GRANT ALL ON FUNCTION public.pia_caller_role() TO service_role;


--
-- Name: FUNCTION pia_can_enter_stage(p_is_ocean_done boolean, p_group_type text, p_selected_character text, p_stage text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pia_can_enter_stage(p_is_ocean_done boolean, p_group_type text, p_selected_character text, p_stage text) TO authenticated;
GRANT ALL ON FUNCTION public.pia_can_enter_stage(p_is_ocean_done boolean, p_group_type text, p_selected_character text, p_stage text) TO service_role;


--
-- Name: FUNCTION pia_choose_assigned_character(p_e integer, p_a integer, p_c integer, p_n integer, p_o integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_choose_assigned_character(p_e integer, p_a integer, p_c integer, p_n integer, p_o integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_choose_assigned_character(p_e integer, p_a integer, p_c integer, p_n integer, p_o integer) TO service_role;


--
-- Name: FUNCTION pia_clear_stage_overrides(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_clear_stage_overrides() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_clear_stage_overrides() TO service_role;


--
-- Name: TABLE game_windows; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.game_windows TO service_role;
GRANT SELECT ON TABLE public.game_windows TO authenticated;


--
-- Name: FUNCTION pia_clock_json(w public.game_windows); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_clock_json(w public.game_windows) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_clock_json(w public.game_windows) TO service_role;


--
-- Name: FUNCTION pia_close_idle_game_sessions(p_dry_run boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_close_idle_game_sessions(p_dry_run boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_close_idle_game_sessions(p_dry_run boolean) TO service_role;


--
-- Name: FUNCTION pia_compute_score(p_base integer, p_errors integer, p_hints integer, p_ms bigint, p_repeat_prior integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_compute_score(p_base integer, p_errors integer, p_hints integer, p_ms bigint, p_repeat_prior integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_compute_score(p_base integer, p_errors integer, p_hints integer, p_ms bigint, p_repeat_prior integer) TO service_role;


--
-- Name: FUNCTION pia_compute_test_scores(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_compute_test_scores() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_compute_test_scores() TO service_role;


--
-- Name: FUNCTION pia_control_stage_guard(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pia_control_stage_guard() TO authenticated;
GRANT ALL ON FUNCTION public.pia_control_stage_guard() TO service_role;


--
-- Name: FUNCTION pia_eval_expr(p_text text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_eval_expr(p_text text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_eval_expr(p_text text) TO service_role;


--
-- Name: FUNCTION pia_forget_deleted_student(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_forget_deleted_student() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_forget_deleted_student() TO service_role;


--
-- Name: FUNCTION pia_format_final(p_kind text, p_value numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_format_final(p_kind text, p_value numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_format_final(p_kind text, p_value numeric) TO service_role;


--
-- Name: FUNCTION pia_game_email(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_game_email() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_game_email() TO service_role;


--
-- Name: FUNCTION pia_game_window(p_session_id uuid, p_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_game_window(p_session_id uuid, p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_game_window(p_session_id uuid, p_email text) TO service_role;


--
-- Name: FUNCTION pia_guard_tutor_choice(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pia_guard_tutor_choice() TO authenticated;
GRANT ALL ON FUNCTION public.pia_guard_tutor_choice() TO service_role;


--
-- Name: FUNCTION pia_has_working(p_text text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_has_working(p_text text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_has_working(p_text text) TO service_role;


--
-- Name: FUNCTION pia_idle_game_windows(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_idle_game_windows() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_idle_game_windows() TO service_role;


--
-- Name: FUNCTION pia_is_final_format(p_kind text, p_text text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_is_final_format(p_kind text, p_text text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_is_final_format(p_kind text, p_text text) TO service_role;


--
-- Name: FUNCTION pia_learning_features_calc(p_session_id uuid, p_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_learning_features_calc(p_session_id uuid, p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_learning_features_calc(p_session_id uuid, p_email text) TO service_role;


--
-- Name: FUNCTION pia_mask_answers(p_text text, p_answers text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_mask_answers(p_text text, p_answers text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_mask_answers(p_text text, p_answers text[]) TO service_role;


--
-- Name: FUNCTION pia_neutral_tutor(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_neutral_tutor() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_neutral_tutor() TO service_role;


--
-- Name: FUNCTION pia_number_key(p_number text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_number_key(p_number text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_number_key(p_number text) TO authenticated;
GRANT ALL ON FUNCTION public.pia_number_key(p_number text) TO service_role;


--
-- Name: FUNCTION pia_on_password_changed(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_on_password_changed() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_on_password_changed() TO service_role;


--
-- Name: FUNCTION pia_parse_hint(p_hint text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_parse_hint(p_hint text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_parse_hint(p_hint text) TO service_role;


--
-- Name: FUNCTION pia_protect_admin_target(p_target text, p_action text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_protect_admin_target(p_target text, p_action text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_protect_admin_target(p_target text, p_action text) TO service_role;


--
-- Name: FUNCTION pia_question_hint_list(p_steps jsonb, p_default text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_question_hint_list(p_steps jsonb, p_default text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_question_hint_list(p_steps jsonb, p_default text) TO service_role;


--
-- Name: TABLE served_questions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.served_questions TO service_role;


--
-- Name: FUNCTION pia_question_payload(p public.served_questions); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_question_payload(p public.served_questions) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_question_payload(p public.served_questions) TO service_role;


--
-- Name: FUNCTION pia_record_stage_grant(p_stage text, p_section text, p_emails text[], p_result jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_record_stage_grant(p_stage text, p_section text, p_emails text[], p_result jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_record_stage_grant(p_stage text, p_section text, p_emails text[], p_result jsonb) TO service_role;


--
-- Name: FUNCTION pia_refuse(p_actor text, p_what text, p_target text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_refuse(p_actor text, p_what text, p_target text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_refuse(p_actor text, p_what text, p_target text) TO service_role;


--
-- Name: FUNCTION pia_registration_rules(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pia_registration_rules() TO authenticated;
GRANT ALL ON FUNCTION public.pia_registration_rules() TO service_role;


--
-- Name: FUNCTION pia_replay_decision_tree(p_classifications text[]); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pia_replay_decision_tree(p_classifications text[]) TO authenticated;
GRANT ALL ON FUNCTION public.pia_replay_decision_tree(p_classifications text[]) TO service_role;


--
-- Name: FUNCTION pia_require_admin(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_require_admin() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_require_admin() TO authenticated;
GRANT ALL ON FUNCTION public.pia_require_admin() TO service_role;


--
-- Name: FUNCTION pia_result_payload(p_session_id uuid, p_email text, p_problem_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_result_payload(p_session_id uuid, p_email text, p_problem_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_result_payload(p_session_id uuid, p_email text, p_problem_id text) TO service_role;


--
-- Name: FUNCTION pia_session_state(p_session_id uuid, p_email text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pia_session_state(p_session_id uuid, p_email text) TO authenticated;
GRANT ALL ON FUNCTION public.pia_session_state(p_session_id uuid, p_email text) TO service_role;


--
-- Name: FUNCTION pia_settle_test_score(p_label text, p_insert boolean, p_raw numeric, p_max numeric, p_score numeric, p_old_raw numeric, p_old_max numeric, p_old_score numeric); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pia_settle_test_score(p_label text, p_insert boolean, p_raw numeric, p_max numeric, p_score numeric, p_old_raw numeric, p_old_max numeric, p_old_score numeric) TO authenticated;
GRANT ALL ON FUNCTION public.pia_settle_test_score(p_label text, p_insert boolean, p_raw numeric, p_max numeric, p_score numeric, p_old_raw numeric, p_old_max numeric, p_old_score numeric) TO service_role;


--
-- Name: FUNCTION pia_stage_open(p_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_stage_open(p_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_stage_open(p_key text) TO authenticated;
GRANT ALL ON FUNCTION public.pia_stage_open(p_key text) TO service_role;


--
-- Name: FUNCTION pia_stamp_base_points(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_stamp_base_points() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_stamp_base_points() TO service_role;


--
-- Name: FUNCTION pia_step_confirm_kind(p_topic integer, p_idx integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_step_confirm_kind(p_topic integer, p_idx integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_step_confirm_kind(p_topic integer, p_idx integer) TO service_role;


--
-- Name: FUNCTION pia_step_hints(p_step jsonb, p_default text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_step_hints(p_step jsonb, p_default text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_step_hints(p_step jsonb, p_default text) TO service_role;


--
-- Name: FUNCTION pia_step_label(p_topic integer, p_idx integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_step_label(p_topic integer, p_idx integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_step_label(p_topic integer, p_idx integer) TO service_role;


--
-- Name: FUNCTION pia_step_matches(p_submitted text, p_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_step_matches(p_submitted text, p_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_step_matches(p_submitted text, p_key text) TO service_role;


--
-- Name: FUNCTION pia_step_required(p_topic integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_step_required(p_topic integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_step_required(p_topic integer) TO service_role;


--
-- Name: TABLE step_states; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.step_states TO service_role;


--
-- Name: FUNCTION pia_step_state_json(sq public.served_questions, st public.step_states); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_step_state_json(sq public.served_questions, st public.step_states) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_step_state_json(sq public.served_questions, st public.step_states) TO service_role;


--
-- Name: FUNCTION pia_steps_valid(p_steps jsonb, p_topic integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_steps_valid(p_steps jsonb, p_topic integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_steps_valid(p_steps jsonb, p_topic integer) TO service_role;


--
-- Name: FUNCTION pia_student_topic(p_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_student_topic(p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_student_topic(p_email text) TO service_role;


--
-- Name: FUNCTION pia_sync_professor(p_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_sync_professor(p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_sync_professor(p_email text) TO service_role;


--
-- Name: FUNCTION pia_tier_label(p_tier integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pia_tier_label(p_tier integer) TO authenticated;
GRANT ALL ON FUNCTION public.pia_tier_label(p_tier integer) TO service_role;


--
-- Name: FUNCTION pia_topic_rules(p_topic integer, OUT mastery integer, OUT min_q integer, OUT max_err integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_topic_rules(p_topic integer, OUT mastery integer, OUT min_q integer, OUT max_err integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_topic_rules(p_topic integer, OUT mastery integer, OUT min_q integer, OUT max_err integer) TO service_role;


--
-- Name: FUNCTION pia_touch_updated_at(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pia_touch_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.pia_touch_updated_at() TO service_role;


--
-- Name: FUNCTION pia_transmute(p_raw numeric, p_max numeric); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pia_transmute(p_raw numeric, p_max numeric) TO authenticated;
GRANT ALL ON FUNCTION public.pia_transmute(p_raw numeric, p_max numeric) TO service_role;


--
-- Name: FUNCTION pia_tutoring_closed(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_tutoring_closed() FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_tutoring_closed() TO service_role;


--
-- Name: FUNCTION pia_tutoring_closed_for(p_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_tutoring_closed_for(p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_tutoring_closed_for(p_email text) TO service_role;


--
-- Name: FUNCTION pia_window_expired(w public.game_windows); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pia_window_expired(w public.game_windows) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pia_window_expired(w public.game_windows) TO service_role;


--
-- Name: FUNCTION professors_claim_section(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.professors_claim_section() TO authenticated;
GRANT ALL ON FUNCTION public.professors_claim_section() TO service_role;


--
-- Name: FUNCTION profiles_guard_privileged_columns(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.profiles_guard_privileged_columns() TO authenticated;
GRANT ALL ON FUNCTION public.profiles_guard_privileged_columns() TO service_role;


--
-- Name: FUNCTION record_heartbeat(p_stage text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_heartbeat(p_stage text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_heartbeat(p_stage text) TO authenticated;
GRANT ALL ON FUNCTION public.record_heartbeat(p_stage text) TO service_role;


--
-- Name: FUNCTION record_problem_result(p_session_id uuid, p_problem_id text, p_problem_number integer, p_level_before integer, p_level_after integer, p_attempts_used integer, p_hints_used integer, p_time_taken_ms integer, p_final_answer numeric, p_classification text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_problem_result(p_session_id uuid, p_problem_id text, p_problem_number integer, p_level_before integer, p_level_after integer, p_attempts_used integer, p_hints_used integer, p_time_taken_ms integer, p_final_answer numeric, p_classification text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_problem_result(p_session_id uuid, p_problem_id text, p_problem_number integer, p_level_before integer, p_level_after integer, p_attempts_used integer, p_hints_used integer, p_time_taken_ms integer, p_final_answer numeric, p_classification text) TO service_role;


--
-- Name: FUNCTION record_problem_result_v2(p_session_id uuid, p_problem_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_problem_result_v2(p_session_id uuid, p_problem_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_problem_result_v2(p_session_id uuid, p_problem_id text) TO service_role;


--
-- Name: FUNCTION record_question_result(p_session_id uuid, p_problem_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_question_result(p_session_id uuid, p_problem_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_question_result(p_session_id uuid, p_problem_id text) TO authenticated;
GRANT ALL ON FUNCTION public.record_question_result(p_session_id uuid, p_problem_id text) TO service_role;


--
-- Name: FUNCTION release_device(p_device_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.release_device(p_device_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.release_device(p_device_id text) TO authenticated;
GRANT ALL ON FUNCTION public.release_device(p_device_id text) TO service_role;


--
-- Name: FUNCTION reset_my_devices(p_device_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reset_my_devices(p_device_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reset_my_devices(p_device_id text) TO authenticated;
GRANT ALL ON FUNCTION public.reset_my_devices(p_device_id text) TO service_role;


--
-- Name: FUNCTION respond_topic_offer(p_session_id uuid, p_problem_id text, p_accept boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.respond_topic_offer(p_session_id uuid, p_problem_id text, p_accept boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.respond_topic_offer(p_session_id uuid, p_problem_id text, p_accept boolean) TO authenticated;
GRANT ALL ON FUNCTION public.respond_topic_offer(p_session_id uuid, p_problem_id text, p_accept boolean) TO service_role;


--
-- Name: FUNCTION restart_after_expiry(p_session_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.restart_after_expiry(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.restart_after_expiry(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.restart_after_expiry(p_session_id uuid) TO service_role;


--
-- Name: FUNCTION resume_or_start_game_session(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resume_or_start_game_session() FROM PUBLIC;
GRANT ALL ON FUNCTION public.resume_or_start_game_session() TO authenticated;
GRANT ALL ON FUNCTION public.resume_or_start_game_session() TO service_role;


--
-- Name: FUNCTION reveal_question_solution(p_session_id uuid, p_problem_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reveal_question_solution(p_session_id uuid, p_problem_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reveal_question_solution(p_session_id uuid, p_problem_id text) TO authenticated;
GRANT ALL ON FUNCTION public.reveal_question_solution(p_session_id uuid, p_problem_id text) TO service_role;


--
-- Name: FUNCTION reveal_solution(p_session_id uuid, p_problem_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reveal_solution(p_session_id uuid, p_problem_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reveal_solution(p_session_id uuid, p_problem_id text) TO service_role;


--
-- Name: FUNCTION serve_next_question(p_session_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.serve_next_question(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.serve_next_question(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.serve_next_question(p_session_id uuid) TO service_role;


--
-- Name: FUNCTION serve_next_step_question(p_session_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.serve_next_step_question(p_session_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.serve_next_step_question(p_session_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.serve_next_step_question(p_session_id uuid) TO service_role;


--
-- Name: FUNCTION serve_problem(p_session_id uuid, p_problem_id text, p_problem_number integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.serve_problem(p_session_id uuid, p_problem_id text, p_problem_number integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.serve_problem(p_session_id uuid, p_problem_id text, p_problem_number integer) TO service_role;


--
-- Name: FUNCTION set_student_stage(p_stage text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_student_stage(p_stage text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_student_stage(p_stage text) TO authenticated;
GRANT ALL ON FUNCTION public.set_student_stage(p_stage text) TO service_role;


--
-- Name: FUNCTION start_game_session(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.start_game_session() FROM PUBLIC;
GRANT ALL ON FUNCTION public.start_game_session() TO authenticated;
GRANT ALL ON FUNCTION public.start_game_session() TO service_role;


--
-- Name: FUNCTION submit_ocean_results(p_responses integer[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.submit_ocean_results(p_responses integer[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_ocean_results(p_responses integer[]) TO authenticated;
GRANT ALL ON FUNCTION public.submit_ocean_results(p_responses integer[]) TO service_role;


--
-- Name: FUNCTION submit_ocean_results_teacher(p_responses integer[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.submit_ocean_results_teacher(p_responses integer[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_ocean_results_teacher(p_responses integer[]) TO authenticated;
GRANT ALL ON FUNCTION public.submit_ocean_results_teacher(p_responses integer[]) TO service_role;


--
-- Name: FUNCTION teacher_class_status(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.teacher_class_status() FROM PUBLIC;
GRANT ALL ON FUNCTION public.teacher_class_status() TO authenticated;
GRANT ALL ON FUNCTION public.teacher_class_status() TO service_role;


--
-- Name: FUNCTION teacher_my_sections(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.teacher_my_sections() FROM PUBLIC;
GRANT ALL ON FUNCTION public.teacher_my_sections() TO authenticated;
GRANT ALL ON FUNCTION public.teacher_my_sections() TO service_role;


--
-- Name: FUNCTION teacher_revoke_device(p_device_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.teacher_revoke_device(p_device_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.teacher_revoke_device(p_device_id text) TO authenticated;
GRANT ALL ON FUNCTION public.teacher_revoke_device(p_device_id text) TO service_role;


--
-- Name: FUNCTION teacher_section_roster(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.teacher_section_roster() FROM PUBLIC;
GRANT ALL ON FUNCTION public.teacher_section_roster() TO authenticated;
GRANT ALL ON FUNCTION public.teacher_section_roster() TO service_role;


--
-- Name: FUNCTION teacher_set_section(p_section text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.teacher_set_section(p_section text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.teacher_set_section(p_section text) TO authenticated;
GRANT ALL ON FUNCTION public.teacher_set_section(p_section text) TO service_role;


--
-- Name: FUNCTION touch_presence(p_online boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.touch_presence(p_online boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.touch_presence(p_online boolean) TO authenticated;
GRANT ALL ON FUNCTION public.touch_presence(p_online boolean) TO service_role;


--
-- Name: FUNCTION tutoring_status(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.tutoring_status() FROM PUBLIC;
GRANT ALL ON FUNCTION public.tutoring_status() TO authenticated;
GRANT ALL ON FUNCTION public.tutoring_status() TO service_role;


--
-- Name: TABLE app_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.app_config TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.app_config TO authenticated;


--
-- Name: TABLE attendance_marks; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.attendance_marks TO service_role;


--
-- Name: TABLE checkins; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.checkins TO service_role;


--
-- Name: TABLE game_sessions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.game_sessions TO service_role;


--
-- Name: TABLE hint_consumptions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.hint_consumptions TO service_role;


--
-- Name: SEQUENCE hint_consumptions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.hint_consumptions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.hint_consumptions_id_seq TO service_role;


--
-- Name: TABLE join_attempts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.join_attempts TO service_role;


--
-- Name: SEQUENCE join_attempts_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.join_attempts_id_seq TO service_role;


--
-- Name: TABLE join_requests; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.join_requests TO service_role;


--
-- Name: TABLE math_answers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.math_answers TO service_role;


--
-- Name: TABLE math_attempt_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.math_attempt_log TO authenticated;
GRANT ALL ON TABLE public.math_attempt_log TO service_role;


--
-- Name: SEQUENCE math_attempt_log_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.math_attempt_log_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.math_attempt_log_id_seq TO service_role;


--
-- Name: TABLE math_attempts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.math_attempts TO service_role;


--
-- Name: SEQUENCE math_attempts_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.math_attempts_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.math_attempts_id_seq TO service_role;


--
-- Name: TABLE math_hints; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.math_hints TO service_role;


--
-- Name: TABLE ocean_submissions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ocean_submissions TO service_role;
GRANT SELECT ON TABLE public.ocean_submissions TO authenticated;


--
-- Name: SEQUENCE ocean_submissions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.ocean_submissions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ocean_submissions_id_seq TO service_role;


--
-- Name: TABLE problem_serves; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.problem_serves TO service_role;


--
-- Name: TABLE professor_sections; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.professor_sections TO service_role;


--
-- Name: TABLE professors; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.professors TO authenticated;
GRANT ALL ON TABLE public.professors TO service_role;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.profiles TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.profiles TO authenticated;


--
-- Name: TABLE question_attempts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.question_attempts TO service_role;


--
-- Name: SEQUENCE question_attempts_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.question_attempts_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.question_attempts_id_seq TO service_role;


--
-- Name: TABLE question_bank; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.question_bank TO service_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.question_bank TO authenticated;


--
-- Name: SEQUENCE question_bank_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.question_bank_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.question_bank_id_seq TO service_role;


--
-- Name: TABLE sections; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,MAINTAIN ON TABLE public.sections TO authenticated;
GRANT ALL ON TABLE public.sections TO service_role;


--
-- Name: SEQUENCE sections_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.sections_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.sections_id_seq TO service_role;


--
-- Name: TABLE security_audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.security_audit_log TO service_role;
GRANT SELECT ON TABLE public.security_audit_log TO authenticated;


--
-- Name: SEQUENCE security_audit_log_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.security_audit_log_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.security_audit_log_id_seq TO service_role;


--
-- Name: TABLE session_start_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.session_start_log TO authenticated;
GRANT ALL ON TABLE public.session_start_log TO service_role;


--
-- Name: SEQUENCE session_start_log_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.session_start_log_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.session_start_log_id_seq TO service_role;


--
-- Name: TABLE settings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.settings TO authenticated;
GRANT ALL ON TABLE public.settings TO service_role;


--
-- Name: TABLE stage_overrides; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.stage_overrides TO service_role;
GRANT SELECT ON TABLE public.stage_overrides TO authenticated;


--
-- Name: SEQUENCE stage_overrides_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.stage_overrides_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.stage_overrides_id_seq TO service_role;


--
-- Name: TABLE step_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.step_events TO service_role;
GRANT SELECT ON TABLE public.step_events TO authenticated;


--
-- Name: SEQUENCE step_events_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.step_events_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.step_events_id_seq TO service_role;


--
-- Name: TABLE step_hints; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.step_hints TO service_role;
GRANT SELECT ON TABLE public.step_hints TO authenticated;


--
-- Name: SEQUENCE step_hints_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.step_hints_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.step_hints_id_seq TO service_role;


--
-- Name: TABLE student_numbers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.student_numbers TO service_role;


--
-- Name: TABLE student_presence; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.student_presence TO service_role;


--
-- Name: TABLE student_stage_time; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.student_stage_time TO service_role;
GRANT SELECT ON TABLE public.student_stage_time TO authenticated;


--
-- Name: TABLE student_topic_progress; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.student_topic_progress TO service_role;
GRANT SELECT ON TABLE public.student_topic_progress TO authenticated;


--
-- Name: TABLE topic_changes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.topic_changes TO service_role;
GRANT SELECT ON TABLE public.topic_changes TO authenticated;


--
-- Name: SEQUENCE topic_changes_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.topic_changes_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.topic_changes_id_seq TO service_role;


--
-- Name: TABLE topic_offers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.topic_offers TO service_role;
GRANT SELECT ON TABLE public.topic_offers TO authenticated;


--
-- Name: TABLE tutoring_attempts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.tutoring_attempts TO authenticated;
GRANT ALL ON TABLE public.tutoring_attempts TO service_role;


--
-- Name: SEQUENCE tutoring_attempts_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.tutoring_attempts_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.tutoring_attempts_id_seq TO service_role;


--
-- Name: TABLE tutoring_schedule; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tutoring_schedule TO service_role;
GRANT SELECT ON TABLE public.tutoring_schedule TO authenticated;


--
-- Name: TABLE v_tutoring_session_summary; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.v_tutoring_session_summary TO authenticated;
GRANT ALL ON TABLE public.v_tutoring_session_summary TO service_role;


--
-- Name: TABLE v_student_tutoring_export; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.v_student_tutoring_export TO authenticated;
GRANT ALL ON TABLE public.v_student_tutoring_export TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- PostgreSQL database dump complete
--


