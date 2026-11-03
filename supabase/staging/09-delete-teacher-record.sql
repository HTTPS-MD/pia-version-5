-- Removing a teacher also removes their professors row and section links.
-- Before this, admin_delete_user() deleted only the profile and the login,
-- so the teacher stayed in the Faculty list.
create or replace function public.pia_delete_teacher_rows()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  delete from public.professors         where lower(email) = lower(old.email);
  delete from public.professor_sections where lower(email) = lower(old.email);
  return old;
end;
$$;

drop trigger if exists profiles_delete_teacher_rows on public.profiles;
create trigger profiles_delete_teacher_rows
  after delete on public.profiles
  for each row execute function public.pia_delete_teacher_rows();

-- Clear teachers that were already removed but left behind.
delete from public.professors p
 where not exists (select 1 from public.profiles x where lower(x.email) = lower(p.email));
delete from public.professor_sections s
 where not exists (select 1 from public.profiles x where lower(x.email) = lower(s.email));
