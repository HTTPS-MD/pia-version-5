-- The teacher sees the three topic boxes live, like the admin (the numbers may still be changing).
-- Run in the Supabase SQL editor (project PIA-Staging) AFTER file 28. Safe to run more than once.
-- Replaces one function. No table and no row changes.
--
-- Before: the boxes answered only after the admin closed the Game. Now they answer for the teacher's own section at any time.
-- Still one percentage per topic plus "reached of total"; no per-student value; a teacher only ever gets their own section.
--
-- Rollback: run file 28 again.

drop function if exists public.teacher_topic_accuracy();

create function public.teacher_topic_accuracy()
returns table (topic integer, accuracy numeric, reached integer, total integer)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email   text := lower(auth.jwt() ->> 'email');
  v_section text;
  v_total   integer;
begin
  if not public.jwt_is_current() or public.pia_caller_role() is distinct from 'teacher' then
    return;
  end if;
  select coalesce(nullif(trim(p.section), ''),
                  (select nullif(trim(f.assigned_section), '') from public.professors f where lower(f.email) = v_email limit 1))
    into v_section
    from public.profiles p where lower(p.email) = v_email limit 1;
  if v_section is null then
    return;
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
