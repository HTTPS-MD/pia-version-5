-- The teacher sees the day's attendance live while the session runs, and a final record once the admin closes the Game.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once.
-- Adds one column (checkins.final_at) and replaces teacher_section_roster. No existing row changes.
--
-- Before: the teacher's roster read only an attendance record that was still open, so after End attendance it showed
--         "—" and the teacher never saw the day's result.
-- Now:    - Live (until the Game is closed): Present / Absent / Not marked, plus whether the student has entered.
--         - Final (the admin closed the Game for the section): Present (entered), Absent, or Did not participate
--           (marked Present but never entered). The record does not change after that.
--         - Still only the name, whether the student is online, and the attendance. No student number, group,
--           stage, personality label, result or score.
--
-- admin_finalize_attendance is called by the admin screen when the Game is closed for a section.
--
-- Rollback: run teacher_section_roster from 06-teacher-roster-neutral-stage.sql again (the new column can stay).

alter table public.checkins add column if not exists final_at timestamptz;

create or replace function public.admin_finalize_attendance(p_section text) returns void
    language plpgsql security definer
    set search_path to 'public'
as $$
begin
  perform public.pia_require_admin();
  update public.checkins
     set final_at = coalesce(final_at, now())
   where id = public.pia_current_checkin(p_section)
     and locked_at is not null;
end;
$$;
revoke all on function public.admin_finalize_attendance(text) from public, anon;
grant execute on function public.admin_finalize_attendance(text) to authenticated;

drop function if exists public.teacher_section_roster();

create function public.teacher_section_roster()
returns table(student_key text, full_name text, online boolean, attendance text,
              entered boolean, entered_at timestamptz, final boolean, class_date date)
    language plpgsql stable security definer
    set search_path to 'public'
as $$
declare
  v_email   text := lower(auth.jwt() ->> 'email');
  v_section text;
  v_checkin uuid;
  v_final   boolean := false;
  v_date    date;
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

  -- Today's record for the section (the Philippine calendar day), open or not.
  v_checkin := public.pia_current_checkin(v_section);
  if v_checkin is not null then
    select (c.final_at is not null), (c.started_at at time zone 'Asia/Manila')::date
      into v_final, v_date
      from public.checkins c where c.id = v_checkin;
  end if;

  return query
    select md5(lower(p.email)),
           coalesce(nullif(trim(p.full_name), ''), 'Unnamed student'),
           coalesce(sp.last_seen > now() - interval '2 minutes', false),
           case
             when v_checkin is null then null
             when m.email is null then 'not_marked'
             when not m.present then 'absent'
             when v_final and not (m.entered_at is not null or m.entered_once) then 'did_not_participate'
             else 'present'
           end,
           (m.entered_at is not null or coalesce(m.entered_once, false)),
           m.entered_at,
           v_final,
           v_date
      from public.profiles p
      left join public.student_presence sp on lower(sp.student_email) = lower(p.email)
      left join public.attendance_marks m on m.checkin_id = v_checkin and lower(m.email) = lower(p.email)
     where p.section = v_section
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
     order by p.full_name;
end;
$$;
revoke all on function public.teacher_section_roster() from public;
grant all on function public.teacher_section_roster() to authenticated;
grant all on function public.teacher_section_roster() to service_role;
