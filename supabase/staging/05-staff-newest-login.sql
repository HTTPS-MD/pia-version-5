-- Staff sign in the same way students do: the newest login wins.
-- An admin or teacher who signs in on a second device ends the session on the first.
-- Run this once in the Supabase SQL editor.

CREATE OR REPLACE FUNCTION public.claim_student_session(p_device_id text) RETURNS jsonb
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
