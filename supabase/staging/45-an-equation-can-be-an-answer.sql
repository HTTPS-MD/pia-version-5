-- 45: A student may write the whole equation.
--
-- "50 - 40 = 10" was marked wrong because the math checker does not know "=". The math was right, but it counted as an error,
-- and an error halves the points of the question. Now each side of "=" goes through the same checker, and the answer is right
-- only if every side has the same value and that value is the key. "50 - 40 = 99" and "60 - 40 = 20" are still wrong for 10.
-- Like "0.10 x 20", an equation is working: the student is still asked for the final value, which must be a number only.
--
-- Replaces ONE function (pia_step_matches). Same inputs and outputs, same permissions. No table and no row changes.
-- No Edge Function or browser change is needed. Answers already saved keep the result they got.
-- Run in the Supabase SQL editor (PIA-Staging) AFTER files 42 and 44. Safe to run more than once.
-- Then run supabase/tests/eval-expr-checks.sql to confirm.

create or replace function public.pia_step_matches(p_submitted text, p_key text) RETURNS boolean
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  u numeric := public.pia_eval_expr(p_submitted);
  k numeric := public.pia_eval_expr(p_key);
  v_side text;
  v_val  numeric;
begin
  -- An equation: every side must work out to the key. Each side goes through the same filter as any answer.
  if k is not null and position('=' in coalesce(p_submitted, '')) > 0 then
    foreach v_side in array string_to_array(p_submitted, '=') loop
      v_val := public.pia_eval_expr(v_side);
      if v_val is null or abs(v_val - k) > 0.000001 then
        return false;
      end if;
    end loop;
    return true;
  end if;

  if u is not null and k is not null then
    return abs(u - k) <= 0.000001;
  end if;
  return lower(trim(coalesce(p_submitted, ''))) = lower(trim(coalesce(p_key, '')));
end;
$$;
