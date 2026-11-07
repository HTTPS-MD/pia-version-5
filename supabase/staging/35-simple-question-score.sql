-- Simple scoring rule: a question earns its full points, or half of them. The admin's "Scoring rules" panel is gone.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once.
-- Replaces ONE function (pia_compute_score). No table and no row changes; scores already earned are never rewritten.
--
-- The rule (same arguments as before, so nothing that calls it changes):
--   no wrong answer            -> the question's full base points
--   one or more wrong answers  -> half of the base points (rounded)
--   a question already completed earlier in the same session (a repeat) -> 0, as it was with the default settings
-- Hints, speed and a minimum score no longer change the score. The old app_config.score_* columns stay in the table, unused.
--
-- Rollback: run the pia_compute_score definition of 01-schema.sql again.

create or replace function public.pia_compute_score(
  p_base integer, p_errors integer, p_hints integer, p_ms bigint, p_repeat_prior integer
) returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_base numeric := greatest(0, coalesce(p_base, 0));
begin
  if coalesce(p_repeat_prior, 0) > 0 then
    return 0;
  end if;
  if coalesce(p_errors, 0) = 0 then
    return v_base::int;
  end if;
  return round(v_base / 2.0)::int;
end;
$$;
