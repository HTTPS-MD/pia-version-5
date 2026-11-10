-- 49: Noel (the neutral tutor) is no longer one of the free choices of the Non-assigned group.
--
-- The Non-assigned group picks among the five OCEAN tutors only. Noel belongs to the Neutral group, which is given him
-- automatically (pia_neutral_tutor trigger, unchanged). Before, the guard also accepted 'pia-neutral' as a free choice, so a
-- Non-assigned student could end up with the neutral tutor, which blurs the Non-assigned and Neutral conditions.
--
-- Replaces ONE function (pia_guard_tutor_choice). No table and no row changes. Students who already chose Noel (if any) are NOT
-- changed; check them first with:
--   select email, group_type, selected_character from public.profiles
--    where lower(trim(coalesce(group_type, ''))) in ('non-assigned', 'non_assigned') and selected_character = 'pia-neutral';
-- Run in the Supabase SQL editor (PIA-Staging). Safe to run more than once.
-- Rollback: run pia_guard_tutor_choice from 01-schema.sql again.

create or replace function public.pia_guard_tutor_choice() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if current_user <> 'authenticated' then return new; end if;
  if new.selected_character is not distinct from old.selected_character then return new; end if;
  if public.pia_caller_role() = 'admin' then return new; end if;

  if old.selected_character is null
     and lower(trim(coalesce(old.group_type, ''))) in ('non-assigned', 'non_assigned')
     and new.selected_character in ('pia-open', 'pia-conscientious', 'pia-extravert',
                                    'pia-agreeable', 'pia-calm') then
    return new;
  end if;

  raise exception 'PIA: your tutor is set for you and cannot be changed here.' using errcode = '42501';
end;
$$;
