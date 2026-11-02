-- Run this in the Supabase SQL editor (PIA-Staging first, then production when you are happy).
-- Safe to run again.
--
-- Deleting a section no longer refuses when it has students or a professor.
--   * Students stay in the study with every response and score; their section is simply cleared.
--   * The professor is unassigned (the account stays).
--   * The section's check-ins, join requests, stage overrides and tutoring schedule are removed.

create or replace function public.admin_delete_section(p_name text) returns void
    language plpgsql security definer
    set search_path to 'public'
as $$
declare
  v_name text := trim(coalesce(p_name, ''));
  v_prof text;
begin
  perform public.pia_require_admin();
  if not exists (select 1 from public.sections where name = v_name) then
    raise exception 'That section no longer exists.' using errcode = 'P0001';
  end if;

  for v_prof in select ps.email from public.professor_sections ps where ps.section = v_name loop
    delete from public.professor_sections where section = v_name and email = v_prof;
    perform public.pia_sync_professor(v_prof);
  end loop;

  update public.profiles
     set section = null
   where section = v_name
     and lower(trim(coalesce(role, 'student'))) = 'student';

  delete from public.checkins          where section = v_name;
  delete from public.join_requests     where section = v_name;
  delete from public.stage_overrides   where section = v_name;
  delete from public.tutoring_schedule where section = v_name;
  delete from public.sections          where name = v_name;
end;
$$;

revoke all on function public.admin_delete_section(text) from public;
grant execute on function public.admin_delete_section(text) to authenticated;
grant execute on function public.admin_delete_section(text) to service_role;
