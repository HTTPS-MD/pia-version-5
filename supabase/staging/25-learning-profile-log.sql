-- A record of the learning profile the decision tree gave each student, and a way for the admin to read the latest one.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once.
-- Adds one table (learning_profile_log) and three functions, and replaces pia_forget_deleted_student. No existing row changes.
--
-- What is stored: the student's e-mail (the key used by every other table), the game session, the profile the tree
-- answered (struggling / average / outstanding), how many of the student's last submissions it looked at, and the time.
-- Nothing else. It is written ONLY by the learning-profile Edge Function (with the service role); a student, a teacher
-- and the browser cannot write or read it. The admin reads the latest profile of a section through admin_learning_profiles.
-- It is deleted together with the student (permanent delete), like every other record of that student.
--
-- NOTE FOR THE ADVISER / CERC: this is new data about each student. The profile is produced by provisional rules
-- (see ml-service/docs/rule-methodology.md); it is not a validated educational measure.
--
-- Rollback: drop table public.learning_profile_log; drop function public.record_learning_profile(uuid, text, integer),
--           public.admin_learning_profiles(text); and run pia_forget_deleted_student from 01-schema.sql again.

create table if not exists public.learning_profile_log (
  id            bigint generated always as identity primary key,
  student_email text        not null,
  session_id    uuid        not null,
  profile       text        not null check (profile in ('struggling', 'average', 'outstanding')),
  events        integer     not null check (events >= 0),
  recorded_at   timestamptz not null default now()
);
create index if not exists learning_profile_log_student_time on public.learning_profile_log (student_email, recorded_at desc);
alter table public.learning_profile_log enable row level security;
revoke all on public.learning_profile_log from public, anon, authenticated;

-- Written by the Edge Function only (service role). The e-mail comes from the session, never from the caller.
create or replace function public.record_learning_profile(p_session_id uuid, p_profile text, p_events integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
begin
  select lower(s.student_email) into v_email from public.game_sessions s where s.id = p_session_id;
  if v_email is null then
    return;
  end if;
  insert into public.learning_profile_log (student_email, session_id, profile, events)
  values (v_email, p_session_id, p_profile, greatest(0, coalesce(p_events, 0)));
end;
$$;
revoke all on function public.record_learning_profile(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.record_learning_profile(uuid, text, integer) to service_role;

-- The admin's view: the latest profile of every student of a section (archived students are left out).
create or replace function public.admin_learning_profiles(p_section text)
returns table (email text, profile text, events integer, recorded_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  return query
    select distinct on (lower(p.email)) lower(p.email), l.profile, l.events, l.recorded_at
      from public.profiles p
      join public.learning_profile_log l on l.student_email = lower(p.email)
     where trim(p.section) = trim(p_section)
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
       and p.removed_at is null
     order by lower(p.email), l.recorded_at desc, l.id desc;
end;
$$;
revoke all on function public.admin_learning_profiles(text) from public, anon;
grant execute on function public.admin_learning_profiles(text) to authenticated;

-- A permanently deleted student takes their profile records with them.
create or replace function public.pia_forget_deleted_student() returns trigger
    language plpgsql security definer
    set search_path to 'public'
as $$
begin
  delete from public.student_numbers      where lower(email) = lower(old.email);
  delete from public.join_requests        where lower(email) = lower(old.email);
  delete from public.attendance_marks     where lower(email) = lower(old.email);
  delete from public.learning_profile_log where lower(student_email) = lower(old.email);
  return old;
end;
$$;
