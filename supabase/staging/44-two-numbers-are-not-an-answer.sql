-- 44: Two numbers with only a space between them are not an answer.
--
-- "25 3" was worked out as 25, and "1 1/2" as 0.5: the second number was taken as a setting of the number type and lost.
-- A student could get the value step right with a stray number after the answer. Now such input counts as not a number.
-- "2 + 3", "2 x 3", "PHP 25" and "25 %" are unchanged. Found by supabase/tests/eval-expr-checks.sql; run that file after any change here.
--
-- Replaces ONE function (pia_eval_expr). Same input and output, same permissions. No table and no row changes.
-- Run in the Supabase SQL editor (PIA-Staging). Safe to run more than once.

create or replace function public.pia_eval_expr(p_text text) RETURNS numeric
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $_$
declare
  e text := coalesce(p_text, '');
  r numeric;
begin
  e := replace(e, ',', '');
  e := regexp_replace(e, 'PHP|₱', '', 'gi');
  e := translate(e, '×·÷−', '**/-');
  e := replace(e, '%', '');
  e := regexp_replace(e, '(\d|\))\s*[xX]\s*(\d|\()', '\1*\2', 'g');
  e := btrim(e);

  if e = '' or length(e) > 60 then return null; end if;
  if e !~ '^[0-9+*/(). [:space:]-]+$' then return null; end if;
  if position('--' in e) > 0 or position('/*' in e) > 0 or position('*/' in e) > 0 then
    return null;
  end if;

  -- Two numbers with only a space between them are not an expression. Without this, "25 3" would become
  -- (25)::numeric (3)::numeric, which Postgres reads as numeric(3) and answers 25, and "1 1/2" would answer 0.5.
  if e ~ '[0-9]\s+[0-9.]' then
    return null;
  end if;

  -- Every number becomes numeric first, or 80/100 would be integer division.
  e := regexp_replace(e, '(\d+\.?\d*|\.\d+)', '(\1)::numeric', 'g');

  begin
    execute 'select (' || e || ')::numeric' into r;
  exception when others then
    return null;       -- syntax error, divide by zero, overflow
  end;
  return r;
end;
$_$;
