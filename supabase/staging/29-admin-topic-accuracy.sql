-- The admin sees the same three boxes as the teacher: the class accuracy of each topic, for any section, at any time.
-- Run in the Supabase SQL editor (project PIA-Staging) AFTER file 28. Safe to run more than once.
-- Adds one function. No table and no row changes.
--
-- Same numbers as teacher_topic_accuracy (file 28): per topic, the accuracy of the students who answered (each student counts
-- equally), how many students answered, and how many students the section has (archived students are left out).
-- The difference: it is for the admin only, takes the section as a parameter, and does not wait for the Game to be closed.
--
-- Rollback: drop function public.admin_topic_accuracy(text);

create or replace function public.admin_topic_accuracy(p_section text)
returns table (topic integer, accuracy numeric, reached integer, total integer)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_section text := trim(coalesce(p_section, ''));
  v_total   integer;
begin
  perform public.pia_require_admin();
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
revoke all on function public.admin_topic_accuracy(text) from public, anon;
grant execute on function public.admin_topic_accuracy(text) to authenticated;
