-- The student's Activity (one row per day) now counts a day when the student tried a question at all:
-- a submitted answer (right or wrong) or a hint, even if the question was not finished.
-- Run in the Supabase SQL editor (project PIA-Staging) AFTER file 08. Safe to run more than once.
-- Replaces ONE function (pia_admin_daily_report). No table and no row changes.
--
-- Before: a day showed only if a question was FINISHED that day (tutoring_attempts), so a student who answered
--         or asked for hints but did not finish a question left no trace.
-- Now:    questions       = the questions the student worked on that day (any answer or hint, or finished)
--         finished        = the questions finished that day
--         clean / points / active time still come from the finished questions
--         errors / hints  = as before (every wrong answer, every hint taken)
--
-- Rollback: run file 08 again.

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
           row_number() over (order by w.day) as day_no
      from worked w
      left join finished f on f.day = w.day
      left join errs e on e.day = w.day
      left join hnt h on h.day = w.day
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
