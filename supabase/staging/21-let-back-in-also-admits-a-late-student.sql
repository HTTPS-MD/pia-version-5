-- "Let back in" also works for a student who was refused after the lock.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once. It replaces one function.
-- No table and no row changes.
--
-- Before: Let back in cleared "entered", but a student who never entered before the lock (entered_once = false)
--         was still refused by pia_claim_entry, so the admin's button did nothing for them.
-- Now:    Let back in also sets entered_once = true, so the door lets that student through once.
--
-- Rollback: run admin_let_back_in from 17-attendance-day-is-the-calendar-day.sql again.

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
     set entered_at = null, entered_once = true, refused_count = 0
   where m.checkin_id = v_id and m.email = v_email;
end;
$$;
