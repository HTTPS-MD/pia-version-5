-- Staging fix: a section that was opened by the admin lets in the students who finish later.
-- Safe to run more than once. Run on the STAGING database only.

CREATE OR REPLACE FUNCTION public.set_student_stage(p_stage text) RETURNS jsonb
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
            or v_profile.current_stage is not distinct from p_stage
            or exists (select 1 from public.stage_overrides o
                        where o.stage = substr(v_flag, 7) and o.section = v_profile.section);
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

CREATE OR REPLACE FUNCTION public.pia_record_stage_grant(p_stage text, p_section text, p_emails text[], p_result jsonb) RETURNS jsonb
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

  -- The section is recorded as open even when nobody was ready yet, so students who
  -- finish later can still get in (set_student_stage checks this record).
  insert into public.stage_overrides (stage, section, granted_count, granted_by, granted_at)
  values (p_stage, v_section, v_granted, lower(nullif(auth.jwt() ->> 'email', '')), now())
  on conflict (stage, section) do update
    set granted_count = excluded.granted_count,
        granted_by    = excluded.granted_by,
        granted_at    = excluded.granted_at;

  return p_result;
end;
$$;
