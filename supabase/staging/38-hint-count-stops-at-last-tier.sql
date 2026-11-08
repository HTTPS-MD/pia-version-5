-- 38: Only a hint the student has not seen yet is counted.
--
-- Pressing Hint again on the last tier used to add 1 to step_states.hints and a new row in
-- step_hints, so the admin's daily report could show 20 hints for a step that has 3.
-- Now the last hint is simply shown again and nothing is written.
-- The rest of consume_step_hint is unchanged. The score does not use the hint count, and
-- the learning profile only asks whether a step used a hint, so neither of them changes.
--
-- Run in the Supabase SQL editor (PIA-Staging). No Edge Function or browser change is needed.

create or replace function public.consume_step_hint(p_session_id uuid, p_problem_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
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

  -- Only a new tier is counted. On the last tier the same hint is shown again.
  if v_tier > v_st.hint_tier then
    insert into public.step_hints (session_id, student_email, problem_id, step_index, tier, tiers_total)
    values (p_session_id, v_email, p_problem_id, v_st.step_index, v_tier, cardinality(v_list));

    update public.step_states
       set hint_tier = v_tier, hints = hints + 1, updated_at = now()
     where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
     returning * into v_st;
  end if;

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
