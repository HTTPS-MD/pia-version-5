-- A student's first, middle and last name are kept apart, so Edit participant shows them as they were typed.
-- full_name stays and is still what every list shows. Existing students are split once from full_name:
-- the last word is the last name, the word before it the middle name, the rest the first name.
-- Safe to run more than once: it only fills rows that have no parts yet.
-- Run in the Supabase SQL editor.

alter table public.profiles
  add column if not exists first_name  text,
  add column if not exists middle_name text,
  add column if not exists last_name   text;

update public.profiles p
   set first_name = case
         when n = 1 then w[1]
         when n = 2 then w[1]
         when n = 3 then w[1]
         else array_to_string(w[1:n-2], ' ') end,
       middle_name = case
         when n = 3 then w[2]
         when n >= 4 then w[n-1]
         else null end,
       last_name = case
         when n = 1 then null
         else w[n] end
  from (
    select id,
           regexp_split_to_array(btrim(full_name), '\s+') as w,
           array_length(regexp_split_to_array(btrim(full_name), '\s+'), 1) as n
      from public.profiles
     where full_name is not null and btrim(full_name) <> ''
       and first_name is null and middle_name is null and last_name is null
       and lower(btrim(coalesce(role, 'student'))) not in ('admin', 'teacher')
  ) s
 where p.id = s.id;
