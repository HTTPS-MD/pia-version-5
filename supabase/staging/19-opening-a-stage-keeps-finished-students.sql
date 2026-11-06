-- Opening a stage no longer resets the students who already finished it.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once. It replaces one function.
-- No table and no row changes.
--
-- Before: opening OCEAN for a section set is_ocean_done = false for EVERY student of the section, and opening
--         Choose a tutor set selected_character = null for EVERY student. A student who had finished OCEAN
--         (for example moved into a section whose OCEAN switch was then turned on, or any off-and-on of the
--         switch) had to take the test again. Opening Choose a tutor erased the tutors already chosen.
-- Now:    a student who already finished OCEAN is left alone when OCEAN opens, and a student who already
--         chose a tutor is left alone when Choose a tutor opens. Only the students who have not done it
--         are moved into the stage. They do not appear in "granted" or "skipped".
--
-- To make ONE student do a stage again, use the buttons in the participant profile:
--   "Allow OCEAN retake" and "Allow character re-selection".
--
-- Rollback: run the admin_grant_stage__inner part of 01-schema.sql again.

create or replace function public.admin_grant_stage__inner(
  p_stage text, p_emails text[] default null::text[], p_section text default null::text
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
declare
    v_target_stage text; v_granted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb; v_reason text; r record;
begin
    if not exists (select 1 from public.profiles where email = auth.jwt() ->> 'email' and lower(trim(role)) = 'admin') then
        raise exception 'Only an admin may grant stage access.';
    end if;

    v_target_stage := case p_stage when 'ocean' then 'OCEAN' when 'char' then 'Character Selection' when 'dash' then 'Tutoring Dashboard' else null end;
    if v_target_stage is null then raise exception 'Unknown stage key: %', p_stage; end if;
    if p_emails is null and p_section is null then raise exception 'Provide either p_emails or p_section.'; end if;

    for r in select email, is_ocean_done, selected_character, lower(trim(coalesce(group_type, ''))) as grp from public.profiles
             where coalesce(lower(trim(role)), 'student') = 'student' and ((p_emails is not null and email = any(p_emails)) or (p_section is not null and section = p_section)) loop
        v_reason := null;
        if p_stage = 'char' then
            if not coalesce(r.is_ocean_done, false) then v_reason := 'OCEAN test not yet completed.';
            elsif r.grp not in ('non-assigned', 'non_assigned') then v_reason := 'Group is not non-assigned -- character selection does not apply to them.'; end if;
        elsif p_stage = 'dash' then
            if not coalesce(r.is_ocean_done, false) then v_reason := 'OCEAN test not yet completed.';
            elsif r.grp in ('non-assigned', 'non_assigned') and r.selected_character is null then v_reason := 'Non-assigned but no character has been selected yet.'; end if;
        end if;

        if v_reason is not null then v_skipped := v_skipped || jsonb_build_object('email', r.email, 'reason', v_reason); continue; end if;

        -- Already done: left exactly as they are.
        if p_stage = 'ocean' and coalesce(r.is_ocean_done, false) then continue; end if;
        if p_stage = 'char' and r.selected_character is not null then continue; end if;

        update public.profiles set current_stage = v_target_stage, stage_started_at = now() where email = r.email;
        v_granted := v_granted || to_jsonb(r.email);
    end loop;
    return jsonb_build_object('granted', v_granted, 'skipped', v_skipped);
end;
$$;
