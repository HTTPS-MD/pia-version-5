-- The class accuracy of a topic now says how many students it is based on ("4 of 10 students answered").
-- Run in the Supabase SQL editor (project PIA-Staging) AFTER file 27. Safe to run more than once.
-- Replaces one function (it now returns two more numbers). No table and no row changes.
--
-- Why: a topic that only the strongest students reached (for example 4 of 10) would otherwise look easy (100%). The teacher
-- now sees the accuracy of the students who answered AND how many students that is out of the whole class.
--   reached = students of the section who answered at least once in the topic
--   total   = students of the section (archived students are left out)
-- Still answers only after the admin closed the Game for the teacher's section, and returns no per-student value.
--
-- Rollback: run file 27 again (it brings back the two-column version after dropping this one).

drop function if exists public.teacher_topic_accuracy();

create function public.teacher_topic_accuracy()
returns table (topic integer, accuracy numeric, reached integer, total integer)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_section text := public.teacher_closed_section();
  v_total   integer;
begin
  if v_section is null then
    return;                      -- not a teacher, or the Game is not closed for this section
  end if;
  select count(*)::integer into v_total
    from public.profiles p
   where trim(p.section) = v_section
     and lower(trim(coalesce(p.role, 'student'))) = 'student'
     and p.removed_at is null;
  return query
    with answers as (
      select lower(e.student_email) as email, sq.topic,
             (e.outcome in ('needs_final', 'step_done', 'question_done')) as correct
        from public.step_events e
        join public.served_questions sq
          on sq.session_id = e.session_id and sq.student_email = e.student_email and sq.problem_id = e.problem_id
        join public.profiles p
          on lower(p.email) = lower(e.student_email)
       where trim(p.section) = v_section
         and lower(trim(coalesce(p.role, 'student'))) = 'student'
         and p.removed_at is null
         and e.outcome in ('wrong', 'format_error', 'needs_final', 'step_done', 'question_done')
    ), per_student as (
      select a.email, a.topic, avg(case when a.correct then 1.0 else 0.0 end) as acc
        from answers a group by a.email, a.topic
    )
    select t.topic,
           (select round(avg(ps.acc) * 100, 0) from per_student ps where ps.topic = t.topic),
           (select count(*)::integer from per_student ps where ps.topic = t.topic),
           v_total
      from (values (1), (2), (3)) as t(topic)
     order by t.topic;
end;
$$;
revoke all on function public.teacher_topic_accuracy() from public, anon;
grant execute on function public.teacher_topic_accuracy() to authenticated;
