-- 47: One meaning of "accuracy" everywhere (a step answered right / every step answered), and the Philippine grade.
--
-- Before: the student's profile counted whole questions answered with no mistake ("clean"), while the class-accuracy boxes counted
-- steps. One student could show 0% in the profile and 44% in the box. Now the profile and the daily Activity count steps too:
--     accuracy = steps answered right (step_done + question_done) / (those + wrong + format_error)
-- The old "clean questions" number is kept as clean_percent (and clean_questions), under its own name.
-- The grade is worked out in the browser: grade = accuracy x 50 + 50 (accuracy as a fraction 0..1), rounded.
--
-- Replaces TWO functions (pia_admin_tutorial_report, pia_admin_daily_report). Same inputs, same permissions. No table or row changes.
-- Run in the Supabase SQL editor (PIA-Staging) AFTER file 46. Safe to run more than once.
-- Rollback: run the same two functions from files 01 and 37 again.

create or replace function public.pia_admin_tutorial_report(p_student_email text) RETURNS jsonb
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
           coalesce(sp.steps_correct, 0) as steps_correct,
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
        select count(*) filter (where ev.outcome in ('step_done', 'question_done'))::int as steps_correct
          from public.step_events ev
         where ev.session_id = w.session_id and ev.student_email = w.student_email
           and ev.outcome in ('step_done', 'question_done')
           and ev.happened_at >= w.started_at and ev.happened_at < w.deadline_at
      ) sp on true
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
      'steps_correct', coalesce(sum(steps_correct), 0)::int,
      'steps_wrong', coalesce(sum(errors), 0)::int,
      'accuracy_percent', case when coalesce(sum(steps_correct), 0) + coalesce(sum(errors), 0) > 0
        then round(sum(steps_correct)::numeric * 100 / (sum(steps_correct) + sum(errors)), 1)
        else null end,
      'clean_percent', case when coalesce(sum(completed), 0) > 0
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

revoke all on function public.pia_admin_tutorial_report(text) from public, anon;
grant execute on function public.pia_admin_tutorial_report(text) to authenticated;
grant execute on function public.pia_admin_tutorial_report(text) to service_role;

create or replace function public.pia_admin_daily_report(p_student_email text) returns jsonb
    language plpgsql security definer
    set search_path to 'public'
as $$
declare
  v_email text := lower(trim(coalesce(p_student_email, '')));
  v_days  jsonb;
  v_total integer;
begin
  if coalesce(public.pia_caller_role(), '') <> 'admin'
     or public.jwt_is_current() is not true then
    raise exception 'PIA: admin access required.' using errcode = '42501';
  end if;
  if v_email = '' then
    raise exception 'PIA: student email required.' using errcode = '22023';
  end if;

  with touched as (
    select (ev.happened_at at time zone 'Asia/Manila')::date as day, ev.session_id, ev.problem_id,
           ev.happened_at as at
      from public.step_events ev
     where lower(ev.student_email) = v_email and ev.problem_id like 'qb-%'
    union all
    select (sh.taken_at at time zone 'Asia/Manila')::date, sh.session_id, sh.problem_id, sh.taken_at
      from public.step_hints sh
     where lower(sh.student_email) = v_email and sh.problem_id like 'qb-%'
    union all
    select (t.recorded_at at time zone 'Asia/Manila')::date, t.session_id, t.problem_id, t.recorded_at
      from public.tutoring_attempts t
     where lower(t.student_email) = v_email and t.problem_id like 'qb-%'
  ), worked as (
    select x.day,
           count(distinct (x.session_id::text || '|' || x.problem_id))::int as questions,
           min(x.at) as first_at,
           max(x.at) as last_at
      from touched x
     group by x.day
  ), done as (
    select t.session_id, t.student_email, t.problem_id, t.is_correct, t.time_taken_ms,
           t.level_before, t.recorded_at,
           (t.recorded_at at time zone 'Asia/Manila')::date as day
      from public.tutoring_attempts t
     where lower(t.student_email) = v_email
       and t.problem_id like 'qb-%'
  ), finished as (
    select d.day,
           count(*)::int as finished,
           count(*) filter (where d.is_correct)::int as clean,
           coalesce(sum(d.time_taken_ms), 0)::numeric / 1000 as active_seconds,
           max(d.level_before) as best_topic,
           coalesce(sum(st.score), 0)::int as points
      from done d
      left join public.step_states st
        on st.session_id = d.session_id and st.student_email = d.student_email
       and st.problem_id = d.problem_id
     group by d.day
  ), errs as (
    select (ev.happened_at at time zone 'Asia/Manila')::date as day, count(*)::int as errors
      from public.step_events ev
     where lower(ev.student_email) = v_email and ev.outcome in ('wrong', 'format_error')
     group by 1
  ), stp as (
    select (ev.happened_at at time zone 'Asia/Manila')::date as day,
           count(*) filter (where ev.outcome in ('step_done', 'question_done'))::int as steps_correct
      from public.step_events ev
     where lower(ev.student_email) = v_email and ev.outcome in ('step_done', 'question_done')
     group by 1
  ), hnt as (
    select (sh.taken_at at time zone 'Asia/Manila')::date as day, count(*)::int as hints
      from public.step_hints sh
     where lower(sh.student_email) = v_email
     group by 1
  ), rows as (
    select w.day, w.questions, w.first_at, w.last_at,
           coalesce(f.finished, 0) as finished, coalesce(f.clean, 0) as clean,
           coalesce(f.active_seconds, 0) as active_seconds, f.best_topic,
           coalesce(f.points, 0) as points,
           coalesce(e.errors, 0) as errors, coalesce(h.hints, 0) as hints,
           coalesce(sp.steps_correct, 0) as steps_correct,
           row_number() over (order by w.day) as day_no
      from worked w
      left join finished f on f.day = w.day
      left join errs e on e.day = w.day
      left join hnt h on h.day = w.day
      left join stp sp on sp.day = w.day
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'day_no', r.day_no,
           'day', r.day,
           'questions', r.questions,
           'finished', r.finished,
           'clean', r.clean,
           'active_seconds', round(r.active_seconds)::int,
           'best_topic', r.best_topic,
           'points', r.points,
           'steps_correct', r.steps_correct,
           'steps_wrong', r.errors,
           'errors', r.errors,
           'hints', r.hints,
           'first_at', r.first_at,
           'last_at', r.last_at
         ) order by r.day_no), '[]'::jsonb),
         coalesce(sum(round(r.active_seconds)::int), 0)::int
    into v_days, v_total
    from rows r;

  return jsonb_build_object('days', v_days, 'active_seconds_total', v_total);
end;
$$;

revoke all on function public.pia_admin_daily_report(text) from public;
grant execute on function public.pia_admin_daily_report(text) to authenticated;
grant execute on function public.pia_admin_daily_report(text) to service_role;
