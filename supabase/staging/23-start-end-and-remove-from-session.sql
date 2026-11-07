-- Start / End, "Remove from this session", and a teacher who sees only who has entered.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once.
-- Adds two columns (profiles.removed_at, profiles.removed_reason) and replaces a few functions. No row changes.
--
-- The new way of working
--   * The teacher takes the roll face to face, outside the system. Nobody is marked Present or Absent in the system.
--   * A student who is not there is taken out of THIS session with "Remove from this session" (and a reason).
--     The student, the answers and the account stay; only the roster, the live count, the door and the teacher's
--     list stop counting them. "Add back" undoes it. Nothing is deleted.
--   * Start opens the door for every student who is on the roster. End closes it: a student who never entered can no
--     longer enter; a student who already entered can still be let back in by the admin.
--   * The teacher sees only "Entered" / "Not in yet", live. No final record, no labels, no download.
--   * Opening a stage moves only students who entered the session, and never a removed student.
--
-- Rollback: run the earlier versions of these functions again (15, 17, 20, 22 and 01-schema.sql); the columns can stay.

alter table public.profiles add column if not exists removed_at timestamptz;
alter table public.profiles add column if not exists removed_reason text;

-- Only an admin (through the functions below) may change the removal. A student can update their own row.
create or replace function public.profiles_guard_removal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.removed_at is distinct from old.removed_at or new.removed_reason is distinct from old.removed_reason)
     and current_user = 'authenticated'
     and not coalesce(public.is_admin(), false) then
    raise exception 'PIA: Only an admin can change this.' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_guard_removal on public.profiles;
create trigger profiles_guard_removal
  before update on public.profiles
  for each row execute function public.profiles_guard_removal();

-- Start: everyone on the roster (not removed) can enter. A mark that already exists is never touched.
create or replace function public.admin_start_checkin(p_section text, p_minutes integer default 15)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_section text := trim(p_section);
  v_id      uuid;
  v_locked  timestamptz;
begin
  perform public.pia_require_admin();
  if nullif(v_section, '') is null then
    raise exception 'PIA: choose a section.' using errcode = 'P0001';
  end if;

  v_id := public.pia_current_checkin(v_section);
  if v_id is not null then
    select c.locked_at into v_locked from public.checkins c where c.id = v_id;
    if v_locked is not null then
      raise exception 'PIA: This session already ended today.' using errcode = 'P0001';
    end if;
    update public.checkins set stopped_at = now()
     where section = v_section and stopped_at is null and id <> v_id;
    update public.checkins
       set stopped_at = null, ends_at = now() + interval '12 hours'
     where id = v_id;
  else
    update public.checkins set stopped_at = now() where section = v_section and stopped_at is null;
    insert into public.checkins (section, ends_at, started_by)
    values (v_section, now() + interval '12 hours', public.current_email())
    returning id into v_id;
  end if;

  insert into public.attendance_marks (checkin_id, email, present)
  select v_id, lower(p.email), true
    from public.profiles p
   where trim(p.section) = v_section
     and lower(trim(coalesce(p.role, 'student'))) = 'student'
     and p.removed_at is null
     and nullif(trim(coalesce(p.email, '')), '') is not null
  on conflict (checkin_id, email) do nothing;

  return v_id;
end;
$$;

-- End: stops and locks the session in one step. It no longer refuses for students without a mark.
create or replace function public.admin_stop_checkin(p_section text) returns void
    language plpgsql security definer
    set search_path to 'public'
as $$
declare
  v_section text := trim(p_section);
  v_id      uuid;
begin
  perform public.pia_require_admin();
  v_id := public.pia_current_checkin(v_section);
  update public.checkins set stopped_at = now() where section = v_section and stopped_at is null;
  if v_id is not null then
    update public.checkins set locked_at = coalesce(locked_at, now()) where id = v_id;
  end if;
end;
$$;

-- A stage cannot open while the session is running; ending it (or the 12-hour ceiling) locks it.
create or replace function public.stage_lock_while_session_open()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  r    record;
begin
  v_id := public.pia_current_checkin(new.section);
  if v_id is null then
    return new;
  end if;
  select c.stopped_at, c.ends_at, c.locked_at into r from public.checkins c where c.id = v_id;
  if r.locked_at is not null then
    return new;
  end if;
  if r.stopped_at is null and r.ends_at > now() then
    raise exception 'PIA: Press End before opening a stage for this section.' using errcode = 'P0001';
  end if;
  update public.checkins set locked_at = now() where id = v_id;
  return new;
end;
$$;

-- A student added (or moved in) while the session is running can enter like everyone else.
create or replace function public.profiles_join_open_session()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if lower(trim(coalesce(new.role, 'student'))) <> 'student'
     or new.removed_at is not null
     or nullif(trim(coalesce(new.email, '')), '') is null
     or nullif(trim(coalesce(new.section, '')), '') is null then
    return new;
  end if;
  v_id := public.pia_current_checkin(new.section);
  if v_id is not null and exists (
       select 1 from public.checkins c
        where c.id = v_id and c.locked_at is null and c.stopped_at is null and c.ends_at > now()) then
    insert into public.attendance_marks (checkin_id, email, present)
    values (v_id, lower(new.email), true)
    on conflict (checkin_id, email) do nothing;
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_join_open_session on public.profiles;
create trigger profiles_join_open_session
  after insert or update of section, removed_at on public.profiles
  for each row execute function public.profiles_join_open_session();

-- Remove a student from this session. Refused when the student already entered (their answers exist).
create or replace function public.admin_remove_from_session(p_email text, p_reason text) returns void
    language plpgsql security definer
    set search_path to 'public'
as $$
declare
  v_email  text := lower(trim(coalesce(p_email, '')));
  v_reason text := left(trim(coalesce(p_reason, '')), 200);
  v_sec    text;
  v_id     uuid;
begin
  perform public.pia_require_admin();
  if v_reason = '' then
    raise exception 'PIA: Write the reason first.' using errcode = 'P0001';
  end if;
  select trim(p.section) into v_sec
    from public.profiles p
   where lower(p.email) = v_email and lower(trim(coalesce(p.role, 'student'))) = 'student';
  if not found then
    raise exception 'PIA: That student was not found.' using errcode = 'P0001';
  end if;
  v_id := public.pia_current_checkin(v_sec);
  if v_id is not null and exists (
       select 1 from public.attendance_marks m
        where m.checkin_id = v_id and m.email = v_email and (m.entered_at is not null or m.entered_once)) then
    raise exception 'PIA: This student already entered, so they cannot be removed.' using errcode = 'P0001';
  end if;
  update public.profiles set removed_at = now(), removed_reason = v_reason where lower(email) = v_email;
  if v_id is not null then
    delete from public.attendance_marks where checkin_id = v_id and email = v_email;
  end if;
end;
$$;
revoke all on function public.admin_remove_from_session(text, text) from public, anon;
grant execute on function public.admin_remove_from_session(text, text) to authenticated;

-- Add back: the student is on the roster again (and can enter, if the session is running).
create or replace function public.admin_add_back_to_session(p_email text) returns void
    language plpgsql security definer
    set search_path to 'public'
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  perform public.pia_require_admin();
  update public.profiles set removed_at = null, removed_reason = null
   where lower(email) = v_email and removed_at is not null;
  -- the trigger profiles_join_open_session gives them a place when the session is running
  update public.profiles set section = section where lower(email) = v_email;
end;
$$;
revoke all on function public.admin_add_back_to_session(text) from public, anon;
grant execute on function public.admin_add_back_to_session(text) to authenticated;

-- Sections' student counts leave out removed students.
create or replace function public.admin_checkin_overview() returns jsonb
    language plpgsql security definer
    set search_path to 'public'
as $$
begin
  perform public.pia_require_admin();

  delete from public.join_requests where created_at < now() - interval '1 day';
  delete from public.join_attempts where at < now() - interval '1 day';

  return jsonb_build_object(
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object(
               'section', s.section, 'students', s.n, 'without_number', s.missing, 'ocean_done', s.ocean) order by s.section)
        from (select trim(p.section) as section, count(*) as n,
                     count(*) filter (where sn.email is null) as missing,
                     count(*) filter (where coalesce(p.is_ocean_done, false)) as ocean
                from public.profiles p
                left join public.student_numbers sn on sn.email = lower(p.email)
               where lower(trim(coalesce(p.role, 'student'))) = 'student' and nullif(trim(p.section), '') is not null
                 and p.removed_at is null
               group by trim(p.section)) s), '[]'::jsonb),
    'open', coalesce((
      select jsonb_agg(jsonb_build_object('section', c.section, 'ends_at', c.ends_at) order by c.section)
        from public.checkins c where c.stopped_at is null and c.ends_at > now()), '[]'::jsonb),
    'waiting', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', w.id, 'section', w.section, 'full_name', w.full_name, 'created_at', w.created_at,
               'duplicate', w.dupes > 1) order by w.created_at)
        from (select r.id, r.section, p.full_name, r.created_at,
                     count(*) over (partition by r.email) as dupes
                from public.join_requests r
                left join public.profiles p on lower(p.email) = r.email
               where r.status = 'waiting' and r.created_at > now() - interval '20 minutes'
                 and exists (select 1 from public.checkins c
                              where c.section = r.section and c.stopped_at is null and c.ends_at > now())) w),
      '[]'::jsonb));
end;
$$;

-- The teacher sees only who is in. entered is null when no session was started today.
drop function if exists public.teacher_section_roster();
create function public.teacher_section_roster()
returns table(student_key text, full_name text, online boolean, entered boolean)
    language plpgsql stable security definer
    set search_path to 'public'
as $$
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

  v_checkin := public.pia_current_checkin(v_section);

  return query
    select md5(lower(p.email)),
           coalesce(nullif(trim(p.full_name), ''), 'Unnamed student'),
           coalesce(sp.last_seen > now() - interval '2 minutes', false),
           case when v_checkin is null then null
                else coalesce(m.entered_at is not null or m.entered_once, false) end
      from public.profiles p
      left join public.student_presence sp on lower(sp.student_email) = lower(p.email)
      left join public.attendance_marks m on m.checkin_id = v_checkin and lower(m.email) = lower(p.email)
     where p.section = v_section
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
       and p.removed_at is null
     order by p.full_name;
end;
$$;
revoke all on function public.teacher_section_roster() from public;
grant all on function public.teacher_section_roster() to authenticated;
grant all on function public.teacher_section_roster() to service_role;

-- The teacher no longer gets a final record.
drop function if exists public.admin_finalize_attendance(text);

-- Opening a stage moves only students who entered the session, and never a removed student.
-- (Same function as 19, with those two conditions added.)
create or replace function public.admin_grant_stage__inner(
  p_stage text, p_emails text[] default null::text[], p_section text default null::text
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
declare
    v_target_stage text; v_granted jsonb := '[]'::jsonb; v_skipped jsonb := '[]'::jsonb; v_reason text; r record;
begin
    if not exists (select 1 from public.profiles where email = auth.jwt() ->> 'email' and lower(trim(role)) = 'admin') then
        raise exception 'Only an admin may grant stage access.';
    end if;

    v_target_stage := case p_stage when 'ocean' then 'OCEAN' when 'char' then 'Character Selection' when 'dash' then 'Tutoring Dashboard' else null end;
    if v_target_stage is null then raise exception 'Unknown stage key: %', p_stage; end if;
    if p_emails is null and p_section is null then raise exception 'Provide either p_emails or p_section.'; end if;

    -- Removed students are never moved. A section grant moves only the students who entered today's session
    -- (a student who never entered cannot sign in anyway).
    for r in select email, is_ocean_done, selected_character, lower(trim(coalesce(group_type, ''))) as grp from public.profiles p
             where coalesce(lower(trim(role)), 'student') = 'student' and p.removed_at is null
               and ((p_emails is not null and email = any(p_emails))
                    or (p_section is not null and section = p_section
                        and exists (select 1 from public.attendance_marks m
                                     where m.checkin_id = public.pia_current_checkin(p.section)
                                       and m.email = lower(p.email)
                                       and (m.entered_at is not null or m.entered_once)))) loop
        v_reason := null;
        if p_stage = 'char' then
            if not coalesce(r.is_ocean_done, false) then v_reason := 'OCEAN test not yet completed.';
            elsif r.grp not in ('non-assigned', 'non_assigned') then v_reason := 'Group is not non-assigned -- character selection does not apply to them.'; end if;
        elsif p_stage = 'dash' then
            if not coalesce(r.is_ocean_done, false) then v_reason := 'OCEAN test not yet completed.';
            elsif r.grp in ('non-assigned', 'non_assigned') and r.selected_character is null then v_reason := 'Non-assigned but no character has been selected yet.'; end if;
        end if;

        if v_reason is not null then v_skipped := v_skipped || jsonb_build_object('email', r.email, 'reason', v_reason); continue; end if;

        -- Already done: left exactly as they are.
        if p_stage = 'ocean' and coalesce(r.is_ocean_done, false) then continue; end if;
        if p_stage = 'char' and r.selected_character is not null then continue; end if;

        update public.profiles set current_stage = v_target_stage, stage_started_at = now() where email = r.email;
        v_granted := v_granted || to_jsonb(r.email);
    end loop;
    return jsonb_build_object('granted', v_granted, 'skipped', v_skipped);
end;
$$;
