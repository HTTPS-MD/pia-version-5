-- The attendance "day" is the calendar day in Philippine time, not the last 16 hours.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once.
-- It replaces three functions. No table and no row changes.
--
-- Before: "today's record" was the newest one that started in the last 16 hours. Two sessions less than
-- 16 hours apart on consecutive days blocked the second Start ("Attendance is final").
-- Now: "today's record" is the newest one that started on today's date in Asia/Manila. At 12:00 AM
-- (Philippine time) the section goes back to "Start attendance".
--
-- The door (join-with-number) uses the same rule: deploy it after this file.
--
-- To test again on a section whose attendance is final today (test sections only), run:
--   update public.checkins set started_at = started_at - interval '1 day'
--    where section = 'MERCURY'
--      and (started_at at time zone 'Asia/Manila')::date = (now() at time zone 'Asia/Manila')::date;
--
-- Rollback: run 15-start-attendance-reopen-and-lock.sql (pia_current_checkin), 12 (admin_attendance)
--           and 14 (admin_let_back_in) again.

create or replace function public.pia_current_checkin(p_section text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select c.id
    from public.checkins c
   where c.section = trim(p_section)
     and (c.started_at at time zone 'Asia/Manila')::date = (now() at time zone 'Asia/Manila')::date
   order by c.started_at desc
   limit 1;
$$;
revoke all on function public.pia_current_checkin(text) from public, anon, authenticated;

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
  v_id := public.pia_current_checkin(p_section);
  return query
    select m.email, m.present, (m.entered_at is not null), m.refused_count
      from public.attendance_marks m
     where m.checkin_id = v_id;
end;
$$;

create or replace function public.admin_let_back_in(p_section text, p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id    uuid;
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  perform public.pia_require_admin();
  v_id := public.pia_current_checkin(p_section);

  insert into public.entry_log (checkin_id, email, kind, by_admin)
  select m.checkin_id, m.email, 'let_back_in', public.current_email()
    from public.attendance_marks m
   where m.checkin_id = v_id and m.email = v_email;

  update public.attendance_marks m
     set entered_at = null, refused_count = 0
   where m.checkin_id = v_id and m.email = v_email;
end;
$$;
