-- Run in the Supabase SQL editor (project PIA-Staging) AFTER file 49. Safe to run more than once.
-- Replaces ONE function: pia_admin_daily_report. Same as before, plus two fields per day:
--   steps_correct  = step_done + question_done submissions that day (Manila date)
--   steps_wrong    = wrong + format_error submissions that day
-- The admin Activity card (admin/js/student-drawer.js) works out "Accuracy" for the day from these two.
-- Before this, the card showed "—" because the function never returned them.
-- The definition of accuracy is the same one admin_topic_accuracy uses. No table and no row changes.
--
-- Rollback: run the pia_admin_daily_report of file 25/previous version again (it has no steps_correct / steps_wrong).

create or replace function public.pia_admin_daily_report(p_student_email text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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

  with done as (
    select t.session_id, t.student_email, t.problem_id, t.is_correct, t.time_taken_ms,
           t.level_before, t.recorded_at,
           (t.recorded_at at time zone 'Asia/Manila')::date as day
      from public.tutoring_attempts t
     where lower(t.student_email) = v_email
       and t.problem_id like 'qb-%'
  ), per_day as (
    select d.day,
           count(*)::int as questions,
           count(*) filter (where d.is_correct)::int as clean,
           coalesce(sum(d.time_taken_ms), 0)::numeric / 1000 as active_seconds,
           max(d.level_before) as best_topic,
           coalesce(sum(st.score), 0)::int as points,
           min(d.recorded_at) as first_at,
           max(d.recorded_at) as last_at
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
           count(*) filter (where ev.outcome in ('step_done', 'question_done'))::int as steps_correct,
           count(*) filter (where ev.outcome in ('wrong', 'format_error'))::int as steps_wrong
      from public.step_events ev
     where lower(ev.student_email) = v_email
     group by 1
  ), hnt as (
    select (sh.taken_at at time zone 'Asia/Manila')::date as day, count(*)::int as hints
      from public.step_hints sh
     where lower(sh.student_email) = v_email
     group by 1
  ), rows as (
    select p.*, coalesce(e.errors, 0) as errors, coalesce(h.hints, 0) as hints,
           coalesce(s.steps_correct, 0) as steps_correct, coalesce(s.steps_wrong, 0) as steps_wrong,
           row_number() over (order by p.day) as day_no
      from per_day p
      left join errs e on e.day = p.day
      left join hnt h on h.day = p.day
      left join stp s on s.day = p.day
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'day_no', r.day_no,
           'day', r.day,
           'questions', r.questions,
           'clean', r.clean,
           'active_seconds', round(r.active_seconds)::int,
           'best_topic', r.best_topic,
           'points', r.points,
           'errors', r.errors,
           'hints', r.hints,
           'steps_correct', r.steps_correct,
           'steps_wrong', r.steps_wrong,
           'first_at', r.first_at,
           'last_at', r.last_at
         ) order by r.day_no), '[]'::jsonb),
         coalesce(sum(round(r.active_seconds)::int), 0)::int
    into v_days, v_total
    from rows r;

  return jsonb_build_object('days', v_days, 'active_seconds_total', v_total);
end;
$function$;
