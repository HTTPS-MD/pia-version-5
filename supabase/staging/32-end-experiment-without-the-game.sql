-- "End experiment" for a section that never used the Game (for example a control-only section).
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once. It adds one function.
-- No table and no row changes when it is run.
--
-- Before: the experiment only ended when the Game stage was closed (the trigger from 26 writes game_closed).
-- Now:    the admin can end it directly: admin_end_experiment(section) writes the same game_closed row.
--         Everything that reads game_closed (Experiment ended, the teacher's class accuracy) works the same.
--
-- Rollback: drop function public.admin_end_experiment(text);
--           and, to reopen a section that was ended today: delete from public.game_closed where section = 'X';

create or replace function public.admin_end_experiment(p_section text) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_section text := trim(coalesce(p_section, ''));
begin
  perform public.pia_require_admin();
  if v_section = '' then
    raise exception 'Choose a section.';
  end if;
  insert into public.game_closed (section) values (v_section)
  on conflict (section) do update set closed_at = now();
end;
$$;
revoke all on function public.admin_end_experiment(text) from public, anon;
grant execute on function public.admin_end_experiment(text) to authenticated;
