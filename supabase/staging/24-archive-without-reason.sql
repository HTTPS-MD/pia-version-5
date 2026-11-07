-- Archive a student with one click: no reason, and a student who already entered can be archived too.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once. It replaces one function.
-- No table and no row changes.
--
-- Before (23): a reason was required, and a student who had already entered was refused.
-- Now:         the reason is optional (kept if one is given), and an archived student who had entered loses
--              their place in today's session. Their answers and account stay. The admin screen signs them out.
--
-- Rollback: run admin_remove_from_session from 23-start-end-and-remove-from-session.sql again.

create or replace function public.admin_remove_from_session(p_email text, p_reason text default null) returns void
    language plpgsql security definer
    set search_path to 'public'
as $$
declare
  v_email  text := lower(trim(coalesce(p_email, '')));
  v_reason text := nullif(left(trim(coalesce(p_reason, '')), 200), '');
  v_sec    text;
  v_id     uuid;
begin
  perform public.pia_require_admin();
  select trim(p.section) into v_sec
    from public.profiles p
   where lower(p.email) = v_email and lower(trim(coalesce(p.role, 'student'))) = 'student';
  if not found then
    raise exception 'PIA: That student was not found.' using errcode = 'P0001';
  end if;
  v_id := public.pia_current_checkin(v_sec);
  update public.profiles set removed_at = now(), removed_reason = v_reason where lower(email) = v_email;
  if v_id is not null then
    delete from public.attendance_marks where checkin_id = v_id and email = v_email;
  end if;
end;
$$;
revoke all on function public.admin_remove_from_session(text, text) from public, anon;
grant execute on function public.admin_remove_from_session(text, text) to authenticated;
