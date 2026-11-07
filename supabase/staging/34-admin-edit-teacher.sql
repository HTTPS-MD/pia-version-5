-- The admin can edit a teacher's details: name, email and the section the teacher is assigned to.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once. It adds one function.
-- No table and no row changes when it is run.
--
-- admin_update_teacher(p_email, p_name, p_new_email, p_section)
--   p_email      the teacher as they are now (must be a teacher)
--   p_name       the new full name
--   p_new_email  the new email (same as before = unchanged). The teacher's LOGIN email changes with it, so every session of
--                that teacher is ended and they sign in again with the new email and their same password.
--   p_section    the section the teacher is assigned to ('' = none). A section has one teacher: if another teacher
--                already has it, the change is refused. The teacher's own section is replaced (one section per teacher here).
-- Only an administrator can call it. Nothing about students changes.
--
-- Rollback: drop function public.admin_update_teacher(text, text, text, text);
--           (an email that was changed stays changed; change it back with the same screen)

create or replace function public.admin_update_teacher(
  p_email text, p_name text, p_new_email text, p_section text
) returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_old     text := lower(trim(coalesce(p_email, '')));
  v_new     text := lower(trim(coalesce(p_new_email, '')));
  v_name    text := trim(coalesce(p_name, ''));
  v_section text := nullif(trim(coalesce(p_section, '')), '');
  v_user    uuid;
begin
  perform public.pia_require_admin();

  if not exists (select 1 from public.professors where lower(email) = v_old) then
    raise exception 'That teacher was not found.' using errcode = 'P0001';
  end if;
  if v_name = '' then
    raise exception 'Full name is required.' using errcode = 'P0001';
  end if;
  if v_new !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a valid email address.' using errcode = 'P0001';
  end if;
  if v_section is not null and not exists (select 1 from public.sections where name = v_section) then
    raise exception 'That section no longer exists.' using errcode = 'P0001';
  end if;
  if v_section is not null and exists (
       select 1 from public.professor_sections ps where ps.section = v_section and lower(ps.email) <> v_old) then
    raise exception 'That section already has a teacher.' using errcode = 'P0001';
  end if;

  -- the email
  if v_new <> v_old then
    if exists (select 1 from public.profiles where lower(email) = v_new)
       or exists (select 1 from public.professors where lower(email) = v_new)
       or exists (select 1 from auth.users where lower(email) = v_new) then
      raise exception 'This email already belongs to another account.' using errcode = 'P0001';
    end if;
    select u.id into v_user from auth.users u where lower(u.email) = v_old;
    if v_user is not null then
      update auth.users set email = v_new, updated_at = now() where id = v_user;
      update auth.identities
         set identity_data = identity_data || jsonb_build_object('email', v_new),
             provider_id   = case when lower(provider_id) = v_old then v_new else provider_id end,
             updated_at    = now()
       where user_id = v_user;
    end if;
    update public.professors         set email = v_new where lower(email) = v_old;
    update public.professor_sections set email = v_new where lower(email) = v_old;
    update public.ocean_submissions  set email = v_new where lower(email) = v_old;
    update public.profiles           set email = v_new where lower(email) = v_old;
    if v_user is not null then
      -- the token of the old email must not keep working
      delete from auth.sessions where user_id = v_user;
    end if;
  end if;

  -- the name
  update public.professors set name = v_name where lower(email) = v_new;
  update public.profiles   set full_name = v_name where lower(email) = v_new;

  -- the section
  delete from public.professor_sections where lower(email) = v_new and section is distinct from v_section;
  if v_section is not null then
    insert into public.professor_sections (email, section) values (v_new, v_section) on conflict do nothing;
  end if;
  perform public.pia_sync_professor(v_new);
end;
$$;
revoke all on function public.admin_update_teacher(text, text, text, text) from public, anon;
grant execute on function public.admin_update_teacher(text, text, text, text) to authenticated;
