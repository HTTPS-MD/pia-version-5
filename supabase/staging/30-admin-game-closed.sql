-- The admin screen learns when the experiment of a section is over (the Game was closed for it).
-- Run in the Supabase SQL editor (project PIA-Staging) AFTER file 26. Safe to run more than once.
-- Adds one function. No table and no row changes.
--
-- game_closed (file 26) holds a mark for a section when the admin closed the Game for it; the mark disappears when the
-- Game is opened again. This function tells the admin screen whether the mark is there, so the stage controls can step
-- aside once the experiment has ended.
--
-- Rollback: drop function public.admin_game_closed(text);

create or replace function public.admin_game_closed(p_section text) returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  return exists (select 1 from public.game_closed g where g.section = trim(coalesce(p_section, '')));
end;
$$;
revoke all on function public.admin_game_closed(text) from public, anon;
grant execute on function public.admin_game_closed(text) to authenticated;
