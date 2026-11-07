-- The admin screen treats the experiment of a section as ended only for the rest of the day the Game was closed.
-- Run in the Supabase SQL editor (project PIA-Staging) AFTER file 30. Safe to run more than once.
-- Replaces one function. No table and no row changes.
--
-- Before: admin_game_closed said "ended" for as long as the mark of file 26 existed (forever).
-- Now:    it says "ended" only when the Game was closed TODAY (Philippine calendar day). The next day the section goes back to
--         "Open gate" and the stage controls follow the normal rules again.
--
-- Rollback: run file 30 again.

create or replace function public.admin_game_closed(p_section text) returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  return exists (
    select 1 from public.game_closed g
     where g.section = trim(coalesce(p_section, ''))
       and (g.closed_at at time zone 'Asia/Manila')::date = (now() at time zone 'Asia/Manila')::date);
end;
$$;
revoke all on function public.admin_game_closed(text) from public, anon;
grant execute on function public.admin_game_closed(text) to authenticated;
