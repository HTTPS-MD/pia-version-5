-- "End attendance" now locks the attendance for good, in the same step.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once. It replaces one function.
-- No table and no row changes.
--
-- Before: End attendance only stopped the record; the lock came later, when the first stage was opened
--         (stage_lock_while_session_open, file 15). Between the two the marks could still be changed,
--         Start attendance could reopen it, and a Present student could still enter.
-- Now:    End attendance locks the record at once: marks cannot change, Start attendance cannot reopen it,
--         and a Present student who has not entered yet can no longer enter (a student who already entered
--         can still be let back in). It refuses while a student of the section is not marked Present or
--         Absent (a student added after Start): mark them first.
--
-- The stage trigger of file 15 stays as it is: it still locks the record if it was never ended by hand
-- (for example the 12-hour ceiling ended it).
--
-- Rollback: run admin_stop_checkin from 01-schema.sql again.

create or replace function public.admin_stop_checkin(p_section text) returns void
    language plpgsql security definer
    set search_path to 'public'
as $$
declare
  v_section text := trim(p_section);
  v_id      uuid;
begin
  perform public.pia_require_admin();
  v_id := public.pia_current_checkin(v_section);

  if v_id is not null and exists (
    select 1 from public.profiles p
     where trim(p.section) = v_section
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
       and nullif(trim(coalesce(p.email, '')), '') is not null
       and not exists (select 1 from public.attendance_marks m
                        where m.checkin_id = v_id and m.email = lower(p.email))
  ) then
    raise exception 'PIA: mark every student Present or Absent before ending attendance.' using errcode = 'P0001';
  end if;

  update public.checkins set stopped_at = now() where section = v_section and stopped_at is null;
  if v_id is not null then
    update public.checkins set locked_at = coalesce(locked_at, now()) where id = v_id;
  end if;
end;
$$;
