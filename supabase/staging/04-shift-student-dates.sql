-- STAGING ONLY. Moves one student's whole tutoring record to a new date, so the admin's
-- "Tutorial performance" and "Session history" show that date and the numbers stay the same.
-- Every timestamp of that student moves by the same amount, so the time windows still match the events inside them.
--
-- How to use: change the two values in the first lines, run the file in the SQL Editor of PIA-Staging
-- (the address must contain qqiudlzqowfemzmefnzl, never hvfqqdtemayhhfavmfbs).
-- The student's first tutoring session will start at 'new_start'; the rest keeps its distance from it.
begin;
set local session_replication_role = replica;

do $$
declare
  v_email     text        := '20269000001@students.pia.invalid';  -- the student's email (student number + @students.pia.invalid)
  v_new_start timestamptz := '2026-10-12 13:59:00+08';             -- when the first session should start
  v_delta     interval;
  r           record;
begin
  select v_new_start - min(started_at) into v_delta
    from public.game_windows where lower(student_email) = lower(v_email);
  if v_delta is null then
    raise exception 'No tutoring windows found for %', v_email;
  end if;

  for r in
    select c.table_name t, c.column_name col,
           (select column_name from information_schema.columns k
             where k.table_schema = 'public' and k.table_name = c.table_name
               and k.column_name in ('student_email', 'email', 'actor_email', 'target_email')
             order by k.column_name = 'student_email' desc limit 1) as who
      from information_schema.columns c
      join information_schema.tables tb on tb.table_schema = c.table_schema and tb.table_name = c.table_name
     where c.table_schema = 'public' and tb.table_type = 'BASE TABLE'
       and c.data_type = 'timestamp with time zone'
       and c.table_name not like '%backup%'
       and c.table_name not in ('security_audit_log', 'join_attempts', 'join_requests', 'checkins')
       and exists (select 1 from information_schema.columns k
                    where k.table_schema = 'public' and k.table_name = c.table_name
                      and k.column_name in ('student_email', 'email'))
  loop
    if r.who in ('student_email', 'email') then
      execute format('update public.%I set %I = %I + $1 where lower(%I) = lower($2) and %I is not null',
                     r.t, r.col, r.col, r.who, r.col) using v_delta, v_email;
    end if;
  end loop;
  raise notice 'Moved % by %', v_email, v_delta;
end $$;

commit;
