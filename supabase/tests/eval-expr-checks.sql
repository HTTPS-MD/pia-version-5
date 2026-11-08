-- Checks for pia_eval_expr, the function that works out the math a student types.
-- It builds a SQL statement from that text, so it is safe only while its character filter holds.
-- Run this after ANY change to pia_eval_expr. It reads nothing and writes nothing.
-- Passing: the run ends with "Success". Failing: it stops and names the input that went wrong.

do $checks$
declare
  good constant text[][] := array[
    ['2+3', '5'], ['(80/100)*50', '40'], ['1,000', '1000'], ['₱25', '25'], ['PHP 25', '25'], ['25%', '25'],
    ['2x3', '6'], ['2 × 3', '6'], ['10÷4', '2.5'], ['−5', '-5'], ['.5', '0.5'], ['0.250', '0.25'], ['25/100', '0.25'],
    ['2 + 3', '5'], ['2 x 3', '6'], ['25 %', '25'], ['₱ 25', '25'], [' 25 ', '25'], ['(2 + 3) * 4', '20']
  ];
  bad constant text[] := array[
    '', '   ', 'abc', 'null', 'true', 'select 1', 'pg_sleep(5)', '1;2', '1;select 1', '1);select 1;--',
    '1''; drop table public.profiles; --', '1) or (1=1', '1::text', '$$', '$1', '"a"', '''a''', '\', '%s',
    '1--1', '1/*x*/2', '1*/2', '1/0', '((1)', '1)', '()', '1e5', '1^2', '2**3', '1 1/2', '25 3', '12 5', '1 000', '1 .5', '½',
    repeat('1', 61), repeat('(', 30) || repeat(')', 30)
  ];
  i int;
  got numeric;
  t0 timestamptz;
begin
  for i in 1 .. array_length(good, 1) loop
    got := public.pia_eval_expr(good[i][1]);
    if got is distinct from good[i][2]::numeric then
      raise exception 'WRONG VALUE for %: got %, expected %', good[i][1], got, good[i][2];
    end if;
  end loop;

  for i in 1 .. array_length(bad, 1) loop
    got := public.pia_eval_expr(bad[i]);
    if got is not null then
      raise exception 'SHOULD BE REFUSED: % (got %)', bad[i], got;
    end if;
  end loop;

  -- The longest inputs allowed must finish at once.
  t0 := clock_timestamp();
  perform public.pia_eval_expr(repeat('9*', 29) || '9');
  perform public.pia_eval_expr(repeat('(', 28) || '1' || repeat(')', 28));
  perform public.pia_eval_expr(repeat('9', 30) || '/' || '.' || repeat('0', 26) || '1');
  if clock_timestamp() - t0 > interval '1 second' then
    raise exception 'TOO SLOW: the longest inputs took %', clock_timestamp() - t0;
  end if;

  raise notice 'All % checks passed.', array_length(good, 1) + array_length(bad, 1) + 1;
end;
$checks$;
