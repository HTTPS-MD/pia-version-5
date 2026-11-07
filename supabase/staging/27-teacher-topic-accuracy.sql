-- The teacher's three boxes show the class's ACCURACY in each topic (replaces the "share who struggled" of file 26).
-- Run in the Supabase SQL editor (project PIA-Staging) AFTER file 26. Safe to run more than once.
-- Adds one function, and removes the per-student functions of file 26 that are no longer needed. No existing row changes.
--
-- What the teacher gets: for each topic (1, 2, 3) one percentage, and nothing else.
--   accuracy of a student in a topic = correct submissions / all submissions of that student in that topic
--   the class accuracy of a topic    = the average of those accuracies over the students who answered in the topic
--   (each student counts equally; a student with no answer in the topic is left out; nobody answered -> null)
-- It answers only after the admin closed the Game for the teacher's section (game_closed, file 26), and not again after
-- the Game is opened. The function works inside the database: no per-student value ever leaves it.
--
-- NOTE FOR THE ADVISER / CERC: class-level performance, shown to the teacher after the experiment. No names, no labels.
--
-- Rollback: drop function public.teacher_topic_accuracy(); and run file 26 again for the per-student functions.

create or replace function public.teacher_topic_accuracy()
returns table (topic integer, accuracy numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_section text := public.teacher_closed_section();
begin
  if v_section is null then
    return;                      -- not a teacher, or the Game is not closed for this section
  end if;
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
           (select round(avg(ps.acc) * 100, 0) from per_student ps where ps.topic = t.topic)
      from (values (1), (2), (3)) as t(topic)
     order by t.topic;
end;
$$;
revoke all on function public.teacher_topic_accuracy() from public, anon;
grant execute on function public.teacher_topic_accuracy() to authenticated;

-- The per-student measurements of file 26 are not needed any more.
drop function if exists public.topic_features_for_section(text);
drop function if exists public.pia_topic_features_calc(text, integer);
