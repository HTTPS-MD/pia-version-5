-- 40: The topic boxes of the teacher and the admin count a step once, like the learning profile (file 39).
--
-- A step answered as working ('needs_final') and then a final value ('step_done') was counted as two correct
-- answers, so the class accuracy looked higher than it was. Now only the finished step counts.
-- A wrong final value ('format_error') still counts as a wrong try.
-- The boxes are worked out each time they are opened, so answers already saved are counted the new way too.
--
-- Replaces TWO functions (teacher_topic_accuracy, admin_topic_accuracy). Same inputs and outputs, same permissions.
-- No table and no row changes. No Edge Function or browser change is needed.
-- Run in the Supabase SQL editor (PIA-Staging) AFTER files 29 and 33. Safe to run more than once.

create or replace function public.teacher_topic_accuracy()
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
             (e.outcome in ('step_done', 'question_done')) as correct
        from public.step_events e
        join public.served_questions sq
          on sq.session_id = e.session_id and sq.student_email = e.student_email and sq.problem_id = e.problem_id
        join public.profiles p
          on lower(p.email) = lower(e.student_email)
       where trim(p.section) = v_section
         and lower(trim(coalesce(p.role, 'student'))) = 'student'
         and p.removed_at is null
         and e.outcome in ('wrong', 'format_error', 'step_done', 'question_done')
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
             (e.outcome in ('step_done', 'question_done')) as correct
        from public.step_events e
        join public.served_questions sq
          on sq.session_id = e.session_id and sq.student_email = e.student_email and sq.problem_id = e.problem_id
        join public.profiles p
          on lower(p.email) = lower(e.student_email)
       where trim(p.section) = v_section
         and lower(trim(coalesce(p.role, 'student'))) = 'student'
         and p.removed_at is null
         and e.outcome in ('wrong', 'format_error', 'step_done', 'question_done')
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
