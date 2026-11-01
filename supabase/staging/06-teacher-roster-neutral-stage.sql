-- The teacher roster no longer says which students reached the tutoring dashboard.
-- A teacher sees three stages only: not_started (waiting room), working (OCEAN, character choice, tutoring)
-- and done (a control student who finished, or the thank-you page). Safe to run more than once. Run in the Supabase SQL editor.

CREATE OR REPLACE FUNCTION public.teacher_section_roster() RETURNS TABLE(student_key text, full_name text, online boolean, stage text, attendance text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_email   text := lower(auth.jwt() ->> 'email');
  v_section text;
  v_checkin uuid;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' then
    raise exception 'PIA: only a teacher can view a class.' using errcode = '42501';
  end if;

  -- The teacher's own section: their profile, else the faculty record the admin assigned.
  select coalesce(
           nullif(trim(p.section), ''),
           (select nullif(trim(f.assigned_section), '') from public.professors f
             where lower(f.email) = v_email limit 1))
    into v_section
    from public.profiles p
   where lower(p.email) = v_email
   limit 1;

  if v_section is null then
    return;
  end if;

  select c.id into v_checkin
    from public.checkins c
   where c.section = v_section and c.stopped_at is null and c.ends_at > now()
   order by c.started_at desc
   limit 1;

  return query
    select md5(lower(p.email)),
           coalesce(nullif(trim(p.full_name), ''), 'Unnamed student'),
           coalesce(sp.last_seen > now() - interval '2 minutes', false),
           case when p.group_type = 'control' and coalesce(p.is_ocean_done, false) then 'done'
                when p.current_stage in ('OCEAN', 'Character Selection', 'Tutoring Dashboard') then 'working'
                when p.current_stage = 'Thank You' then 'done'
                else 'not_started'
           end,
           case when v_checkin is null then null
                else coalesce((select case when m.present then 'present' else 'absent' end
                                 from public.attendance_marks m
                                where m.checkin_id = v_checkin and lower(m.email) = lower(p.email)),
                              'not_marked')
           end
      from public.profiles p
      left join public.student_presence sp on lower(sp.student_email) = lower(p.email)
     where p.section = v_section
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
     order by p.full_name;
end;
$$;
