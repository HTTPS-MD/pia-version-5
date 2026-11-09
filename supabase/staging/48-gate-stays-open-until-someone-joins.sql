-- The gate (attendance session) cannot be closed until at least one student has entered.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once. It replaces one function.
-- No table and no row changes.
--
-- Rollback: run admin_stop_checkin from 23-start-end-and-remove-from-session.sql again.

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

  if v_id is not null and not exists (
    select 1 from public.attendance_marks m
     where m.checkin_id = v_id and m.entered_at is not null
  ) then
    raise exception 'PIA: Nobody has joined yet. The gate stays open until at least one student enters.' using errcode = 'P0001';
  end if;

  update public.checkins set stopped_at = now() where section = v_section and stopped_at is null;
  if v_id is not null then
    update public.checkins set locked_at = coalesce(locked_at, now()) where id = v_id;
  end if;
end;
$$;
