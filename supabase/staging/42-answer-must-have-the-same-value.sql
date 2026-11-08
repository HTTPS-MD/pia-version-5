-- 42: An answer must have the same value as the key.
--
-- A difference of up to 0.001 was accepted, which is a lot for a Conversion step: 0.251 passed for 0.25 and 0.049 for 0.05.
-- Now the value must match. The very small allowance left (0.000001) only absorbs rounding inside the computer, for example (100/3)*3.
-- Answers with the same value still pass: 0.25, 0.250, .25, 25/100, 1,000.
--
-- Replaces TWO functions (pia_step_matches, check_step_answer). Same inputs and outputs, same permissions.
-- No table and no row changes. No Edge Function or browser change is needed.
-- Run in the Supabase SQL editor (PIA-Staging). Safe to run more than once.

create or replace function public.pia_step_matches(p_submitted text, p_key text) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  u numeric := public.pia_eval_expr(p_submitted);
  k numeric := public.pia_eval_expr(p_key);
begin
  if u is not null and k is not null then
    return abs(u - k) <= 0.000001;
  end if;
  return lower(trim(coalesce(p_submitted, ''))) = lower(trim(coalesce(p_key, '')));
end;
$$;

create or replace function public.check_step_answer(p_session_id uuid, p_problem_id text, p_submitted text) RETURNS jsonb
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
    if v_num is not null and v_key is not null and abs(v_num - v_key) <= 0.000001 then
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
