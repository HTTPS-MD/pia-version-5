-- Run this in the Supabase SQL editor (PIA-Staging first, then production when you are happy).
-- Safe to run again.
--
-- 1. admin_move_students: move one or many students to another section. Nothing else about the
--    student changes (stage, condition, answers, scores).
-- 2. admin_delete_section: a section with students can be deleted only when you say where they go.
--    The professor is unassigned (the account stays) and the section's check-ins, join requests,
--    stage overrides and tutoring schedule are removed.

create or replace function public.admin_move_students(p_emails text[], p_section text) returns integer
    language plpgsql security definer
    set search_path to 'public'
as $$
declare
  v_section text := trim(coalesce(p_section, ''));
  v_count integer;
begin
  perform public.pia_require_admin();
  if not exists (select 1 from public.sections where name = v_section) then
    raise exception 'That section no longer exists.' using errcode = 'P0001';
  end if;
  update public.profiles p
     set section = v_section
   where lower(p.email) = any (select lower(e) from unnest(coalesce(p_emails, '{}'::text[])) e)
     and lower(trim(coalesce(p.role, 'student'))) = 'student';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.admin_move_students(text[], text) from public;
grant execute on function public.admin_move_students(text[], text) to authenticated;
grant execute on function public.admin_move_students(text[], text) to service_role;

drop function if exists public.admin_delete_section(text);

create or replace function public.admin_delete_section(p_name text, p_move_to text default null) returns void
    language plpgsql security definer
    set search_path to 'public'
as $$
declare
  v_name text := trim(coalesce(p_name, ''));
  v_to   text := nullif(trim(coalesce(p_move_to, '')), '');
  v_prof text;
begin
  perform public.pia_require_admin();
  if not exists (select 1 from public.sections where name = v_name) then
    raise exception 'That section no longer exists.' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.profiles
              where section = v_name and lower(trim(coalesce(role, 'student'))) = 'student') then
    if v_to is null or v_to = v_name or not exists (select 1 from public.sections where name = v_to) then
      raise exception 'Choose another section for the students.' using errcode = 'P0001';
    end if;
    update public.profiles
       set section = v_to
     where section = v_name and lower(trim(coalesce(role, 'student'))) = 'student';
  end if;

  for v_prof in select ps.email from public.professor_sections ps where ps.section = v_name loop
    delete from public.professor_sections where section = v_name and email = v_prof;
    perform public.pia_sync_professor(v_prof);
  end loop;

  delete from public.checkins          where section = v_name;
  delete from public.join_requests     where section = v_name;
  delete from public.stage_overrides   where section = v_name;
  delete from public.tutoring_schedule where section = v_name;
  delete from public.sections          where name = v_name;
end;
$$;

revoke all on function public.admin_delete_section(text, text) from public;
grant execute on function public.admin_delete_section(text, text) to authenticated;
grant execute on function public.admin_delete_section(text, text) to service_role;
