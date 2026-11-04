-- Open session / Close session: the attendance record stays after the session ends, and a stage cannot
-- be opened for a section while its session is open.
-- Run in the Supabase SQL editor. Safe to run more than once. It changes no table and no row.
--
-- 1. admin_attendance(section) used to answer only while the session was open, so the Present / Absent
--    marks vanished from the dashboard the moment the admin closed it (or the timer ran out).
--    It now answers with the marks of the newest session for that section, open or closed, as long as
--    that session started in the last 16 hours. Older marks are not shown on a new day.
-- 2. A section grant of a stage (OCEAN test, Choose tutor) writes a stage_overrides row in the same
--    transaction. A trigger on that table now refuses the row while the section has an open session,
--    so the whole grant is rolled back and nobody is moved.
--    The Game stage is opened by a tutoring schedule, which this does not cover: the dashboard keeps
--    its switch locked while the session is open.
--
-- Rollback: put admin_attendance back as in 0058 (filter on stopped_at is null and ends_at > now()),
--   and: drop trigger if exists stage_overrides_lock on public.stage_overrides;
--        drop function if exists public.stage_lock_while_session_open();

create or replace function public.admin_attendance(p_section text)
returns table (email text, present boolean, entered boolean, refused int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform public.pia_require_admin();
  select c.id into v_id
    from public.checkins c
   where c.section = trim(p_section)
     and c.started_at > now() - interval '16 hours'
   order by c.started_at desc
   limit 1;
  return query
    select m.email, m.present, (m.entered_at is not null), m.refused_count
      from public.attendance_marks m
     where m.checkin_id = v_id;
end;
$$;

create or replace function public.stage_lock_while_session_open()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public.checkins c
     where c.section = new.section
       and c.stopped_at is null
       and c.ends_at > now()
  ) then
    raise exception 'PIA: close the session before opening a stage for this section.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists stage_overrides_lock on public.stage_overrides;
create trigger stage_overrides_lock
  before insert or update on public.stage_overrides
  for each row execute function public.stage_lock_while_session_open();
