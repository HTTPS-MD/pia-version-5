-- What the teacher may see after the experiment: the share of the whole class that struggled in each topic.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once.
-- Adds one table (game_closed) with two triggers, and four functions (the Edge Function topic-summary uses them). No existing row changes.
--
-- The rules this implements
--   * The teacher sees the three boxes (Topic 1, 2, 3) only AFTER the admin closed the Game for the teacher's section.
--     While the Game is open, or before it was ever closed, nothing is shown. Opening the Game again hides them again.
--   * Only percentages of the whole class reach the teacher's browser. The per-student measurements below can be read by
--     the service role only (the topic-summary Edge Function); a teacher cannot call them, so a teacher can never match a
--     result to a name.
--   * "Struggled in a topic" is decided by the SAME decision tree as the learning profile (ml-service), applied to the
--     student's last eight submissions on that topic. The cut-offs are provisional.
--
-- NOTE FOR THE ADVISER / CERC: this gives the teacher new information about the class. It is class-level only.
--
-- Rollback: drop table public.game_closed cascade; drop function public.teacher_closed_section(),
--   public.topic_features_for_section(text), public.pia_topic_features_calc(text, integer),
--   public.mark_game_closed(), public.clear_game_closed();

-- ---------------------------------------------------------------- the Game closed mark
create table if not exists public.game_closed (
  section   text primary key,
  closed_at timestamptz not null default now()
);
alter table public.game_closed enable row level security;
revoke all on public.game_closed from public, anon, authenticated;

create or replace function public.mark_game_closed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.stage = 'dash' then
    insert into public.game_closed (section) values (old.section)
    on conflict (section) do update set closed_at = now();
  end if;
  return old;
end;
$$;
drop trigger if exists stage_overrides_game_closed on public.stage_overrides;
create trigger stage_overrides_game_closed
  after delete on public.stage_overrides
  for each row execute function public.mark_game_closed();

create or replace function public.clear_game_closed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.stage = 'dash' then
    delete from public.game_closed where section = new.section;
  end if;
  return new;
end;
$$;
drop trigger if exists stage_overrides_game_reopened on public.stage_overrides;
create trigger stage_overrides_game_reopened
  after insert on public.stage_overrides
  for each row execute function public.clear_game_closed();

-- ---------------------------------------------------------------- the teacher: may the boxes be shown?
-- The teacher's section when the Game was closed for it (and not opened again), else null.
create or replace function public.teacher_closed_section() returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_email   text := lower(auth.jwt() ->> 'email');
  v_section text;
begin
  if not public.jwt_is_current() or public.pia_caller_role() is distinct from 'teacher' then
    return null;
  end if;
  select coalesce(nullif(trim(p.section), ''),
                  (select nullif(trim(f.assigned_section), '') from public.professors f where lower(f.email) = v_email limit 1))
    into v_section
    from public.profiles p where lower(p.email) = v_email limit 1;
  if v_section is not null and exists (select 1 from public.game_closed g where g.section = v_section) then
    return v_section;
  end if;
  return null;
end;
$$;
revoke all on function public.teacher_closed_section() from public, anon;
grant execute on function public.teacher_closed_section() to authenticated;

-- ---------------------------------------------------------------- the measurements of ONE student on ONE topic
-- Same measurements as pia_learning_features_calc, but over the student's last eight submissions on this topic
-- (across the student's sessions).
create or replace function public.pia_topic_features_calc(p_email text, p_topic integer) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_n int; v_correct int; v_steps int; v_hinted int; v_streak int; v_last boolean;
  v_acc numeric; v_attempts numeric; v_hint_rate numeric; v_eff numeric; v_time numeric;
  v_cc int := 0; v_cw int := 0;
begin
  with recent as (
    select row_number() over (order by e.id desc)::int as rn,
           e.outcome in ('needs_final', 'step_done', 'question_done') as correct,
           least(300, greatest(0, extract(epoch from (e.happened_at - coalesce(
             (select max(p.at) from (
                select pe.happened_at as at from public.step_events pe
                 where pe.session_id = e.session_id and pe.student_email = e.student_email
                   and pe.id < e.id
                union all
                select sh.taken_at from public.step_hints sh
                 where sh.session_id = e.session_id and sh.student_email = e.student_email
                   and sh.taken_at < e.happened_at) p),
             (select ps.served_at from public.problem_serves ps
               where ps.session_id = e.session_id and ps.student_email = e.student_email
                 and ps.problem_id = e.problem_id
               order by ps.served_at desc limit 1),
             e.happened_at - interval '120 seconds')))))::numeric as rt,
           e.session_id, e.problem_id, e.step_index,
           (select count(*)::int from public.step_events x
             where x.session_id = e.session_id and x.student_email = e.student_email
               and x.problem_id = e.problem_id and x.step_index = e.step_index and x.id <= e.id
               and x.outcome in ('wrong', 'format_error', 'needs_final', 'step_done', 'question_done'))
             as attempt_no,
           exists (select 1 from public.step_hints h
                    where h.session_id = e.session_id and h.student_email = e.student_email
                      and h.problem_id = e.problem_id and h.step_index = e.step_index) as hinted
      from public.step_events e
      join public.served_questions sq
        on sq.session_id = e.session_id and sq.student_email = e.student_email and sq.problem_id = e.problem_id
     where lower(e.student_email) = lower(p_email) and sq.topic = p_topic
       and e.outcome in ('wrong', 'format_error', 'needs_final', 'step_done', 'question_done')
     order by e.id desc
     limit 8
  ), steps as (
    select session_id, problem_id, step_index, bool_or(hinted) as hinted, max(attempt_no) as m
      from recent group by session_id, problem_id, step_index
  )
  select (select count(*) from recent),
         (select count(*) filter (where correct) from recent),
         (select correct from recent where rn = 1),
         coalesce((select min(rn) from recent
                    where correct is distinct from (select correct from recent where rn = 1)),
                  (select count(*) + 1 from recent)) - 1,
         coalesce((select avg(1.0 / (1.0 + rt / 30.0)) filter (where correct) from recent), 0),
         coalesce((select avg(rt) filter (where correct) from recent), 120),
         (select count(*) from steps),
         (select count(*) filter (where hinted) from steps),
         (select avg(m) from steps)
    into v_n, v_correct, v_last, v_streak, v_eff, v_time, v_steps, v_hinted, v_attempts;

  if coalesce(v_n, 0) = 0 then
    return jsonb_build_object('events', 0, 'features', jsonb_build_object(
      'recent_accuracy', 0.5, 'average_attempts', 1, 'hint_rate', 0,
      'average_response_time', 120, 'correct_response_efficiency', 0,
      'consecutive_correct', 0, 'consecutive_wrong', 0));
  end if;

  v_acc := v_correct::numeric / v_n;
  v_attempts := greatest(1, coalesce(v_attempts, 1));
  v_hint_rate := case when v_steps > 0 then v_hinted::numeric / v_steps else 0 end;
  if v_last then v_cc := v_streak; else v_cw := v_streak; end if;

  return jsonb_build_object('events', v_n, 'features', jsonb_build_object(
    'recent_accuracy', round(v_acc, 4),
    'average_attempts', round(v_attempts, 4),
    'hint_rate', round(v_hint_rate, 4),
    'average_response_time', round(v_time, 2),
    'correct_response_efficiency', round(v_eff, 4),
    'consecutive_correct', v_cc,
    'consecutive_wrong', v_cw));
end;
$$;
revoke all on function public.pia_topic_features_calc(text, integer) from public, anon, authenticated;
grant execute on function public.pia_topic_features_calc(text, integer) to service_role;

-- ---------------------------------------------------------------- every student x topic of a section (service role only)
-- No name, no e-mail: a running number per student, so the Edge Function can count students and topics.
create or replace function public.topic_features_for_section(p_section text)
returns table (student_no integer, topic integer, events integer, features jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  return query
    select s.no::integer, t.topic, (f.j ->> 'events')::integer, f.j -> 'features'
      from (select row_number() over (order by p.id) as no, lower(p.email) as email
              from public.profiles p
             where trim(p.section) = trim(p_section)
               and lower(trim(coalesce(p.role, 'student'))) = 'student'
               and p.removed_at is null
               and nullif(trim(coalesce(p.email, '')), '') is not null) s
     cross join (values (1), (2), (3)) as t(topic)
     cross join lateral (select public.pia_topic_features_calc(s.email, t.topic) as j) f
     order by s.no, t.topic;
end;
$$;
revoke all on function public.topic_features_for_section(text) from public, anon, authenticated;
grant execute on function public.topic_features_for_section(text) to service_role;
