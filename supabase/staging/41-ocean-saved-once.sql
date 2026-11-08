-- 41: The OCEAN questionnaire is saved once, even if it is sent twice at the same moment.
--
-- Two submits at the same moment (two tabs, a double request) could both pass the "already submitted" check and
-- save two results. Now the student's row is locked while saving, so the second one waits and is then refused.
-- The student's submit also refuses a session that was signed out, as the teacher's submit and the rest of the system do.
--
-- Replaces TWO functions (submit_ocean_results, submit_ocean_results_teacher). Same inputs and outputs, same permissions.
-- No table and no row changes. No Edge Function or browser change is needed.
-- Run in the Supabase SQL editor (PIA-Staging). Safe to run more than once.

create or replace function public.submit_ocean_results(p_responses integer[]) RETURNS jsonb
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
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  -- The row stays locked until this function ends, so two submits at the same moment run one after the other.
  select * into v_profile from public.profiles where email = v_email for update;
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

create or replace function public.submit_ocean_results_teacher(p_responses integer[]) RETURNS jsonb
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

  -- The row stays locked until this function ends, so two submits at the same moment run one after the other.
  select * into v_profile from public.profiles where email = v_email for update;
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
